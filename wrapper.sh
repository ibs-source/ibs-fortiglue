#!/bin/bash
#
# Fortiglue: nightly synchronisation between IT Glue and the Fortinet services.
#
# Two stages:
#   sync    every Fortinet configuration of IT Glue gets its description written
#           on FortiCare and, when it is a firewall, its name written on
#           FortiAnalyzer;
#   report  every organization holding firewalls gets its scheduled reports
#           rebuilt on FortiAnalyzer, addressed to the contacts named in IT Glue.
#
# Exit codes:
#   0  everything done, no error
#   1  the run completed but at least one operation failed
#   2  the run could not start: environment or sign in problem
#
# The report stage never deletes anything before its replacement exists: if the
# rebuild of an organization fails, yesterday's reports stay in place. More than
# one instance of this tool can share an appliance, each one with its own parent
# folder, so nothing is ever selected for deletion by name.

set -Eeuo pipefail

. /library/system.bash
. /library/itglue.bash
. /library/fortinet/manager.bash
. /library/fortinet/analyzer.bash

WRAPPER_INSTRUCTION="/library/instruction.txt"

# Devices carrying reports are recognised by their name, following the naming
# convention of the firewalls. The pattern can be changed without touching the
# code; the default is spelled out here because a brace inside a parameter
# expansion would close the expansion itself.
WRAPPER_DEVICE_PATTERN='[A-Z0-9]{4}-[A-Z0-9]{2}-FW[0-9]{2}'
if [ -n "${ENVIRONMENT_FORTIANALYZER_DEVICE_PATTERN:-}" ]; then
  WRAPPER_DEVICE_PATTERN="$ENVIRONMENT_FORTIANALYZER_DEVICE_PATTERN"
fi

# ------------------------------------------------------------- environment

# Variables owned by this file: name|requirement|description.
wrapper.environment() {
  cat <<'VARIABLES'
ENVIRONMENT_DRYRUN|flag|When set, no call that writes is ever sent: the run only reports what it would do
ENVIRONMENT_LOG_LEVEL|optional|debug, info, warning or error, default info
ENVIRONMENT_HTTP_RETRY|count|Attempts per HTTP call, default 4
ENVIRONMENT_HTTP_TIMEOUT|count|Deadline in seconds of a single HTTP call, default 120
ENVIRONMENT_HTTP_CONNECT_TIMEOUT|count|Deadline in seconds to open a connection, default 15
ENVIRONMENT_HTTP_BACKOFF|count|Base of the growing pause between two attempts, default 2
ENVIRONMENT_FORTIANALYZER_DEVICE_PATTERN|optional|Regular expression picking the firewalls that get a report
VARIABLES
}

environment.table() {
  wrapper.environment
  itglue.environment
  fortimanager.environment
  fortianalyzer.environment
}

# Checks every declared variable and reports all the problems at once, instead
# of failing on the first one in the middle of the night.
environment.validate() {
  local -a problems=()
  local line name kind description value

  while IFS='|' read -r name kind description; do
    [ -z "$name" ] && continue
    value="${!name:-}"

    # Without the FortiCare stage its credentials are not needed.
    if [ -n "${ENVIRONMENT_FORTINET_NOSYNC:-}" ] && [[ "$name" == ENVIRONMENT_FORTINET_* ]]; then
      kind=optional
    fi

    case "$kind" in
    required)
      [ -z "$value" ] && problems+=("$name is missing: $description")
      ;;
    number)
      if [ -z "$value" ]; then
        problems+=("$name is missing: $description")
      elif ! system.number "$value"; then
        problems+=("$name must be a number: $description")
      fi
      ;;
    count)
      # Optional, but a zero or a word here would turn a loop into a night of
      # nothing, so it is checked as strictly as a required one.
      if [ -n "$value" ] && { ! system.number "$value" || [ "$value" -lt 1 ]; }; then
        problems+=("$name must be a positive number: $description")
      fi
      ;;
    json)
      if [ -n "$value" ] && ! system.json.object "$value"; then
        problems+=("$name must hold a JSON object: $description")
      fi
      ;;
    esac
  done < <(environment.table)

  if [ ${#problems[@]} -ne 0 ]; then
    for line in "${problems[@]}"; do
      system.log error "environment: $line"
    done
    return 1
  fi

  return 0
}

# ------------------------------------------------------------------ staging

wrapper.banner() {
  [ -r "$WRAPPER_INSTRUCTION" ] && cat "$WRAPPER_INSTRUCTION"

  return 0
}

# shellcheck disable=SC2329  # reached through the EXIT trap
wrapper.finish() {
  local status=$?

  fortianalyzer.logout || true
  system.cleanup || true

  return "$status"
}

# shellcheck disable=SC2329  # reached through the signal trap
wrapper.interrupt() {
  system.log.error "Interrupted by a signal, stopping."
  exit 1
}

# ----------------------------------------------------------- stage: sync

# One device: description on FortiCare, name on FortiAnalyzer.
sync.device() {
  local device="$1"

  local label
  label=$($JQ -rc '"[" + ( .name // "" ) + "] - " + ( .organization // "" )' <<<"$device")

  local outcome
  if [ -n "${ENVIRONMENT_FORTINET_NOSYNC:-}" ]; then
    system.log.debug "$label @ FortiCare not attempted, ENVIRONMENT_FORTINET_NOSYNC is set"
  else
    outcome=0
    fortimanager.product.update "$device" || outcome=$?
    case "$outcome" in
    0) system.status ok "$label @ FortiCare" ;;
    2) system.status skip "$label @ FortiCare" ;;
    *) system.status error "$label @ FortiCare" ;;
    esac
  fi

  outcome=0
  fortianalyzer.device.rename "$device" || outcome=$?
  case "$outcome" in
  0) system.status ok "$label @ FortiAnalyzer" ;;
  2) system.status skip "$label @ FortiAnalyzer" ;;
  *) system.status error "$label @ FortiAnalyzer" ;;
  esac

  return 0
}

sync.run() {
  system.log.info "Naming synchronisation between IT Glue and the Fortinet services."

  local configurations
  if ! configurations=$(itglue.get.all itglue.configuration.get); then
    system.log.error "The list of IT Glue configurations could not be read, the sync stage is skipped."
    return 1
  fi

  local total fortinet
  total=$($JQ -r 'length' <<<"$configurations")
  fortinet=$($JQ -r '[ .[] | select( .manufacturer == "Fortinet" ) ] | length' <<<"$configurations")
  system.log.info "IT Glue returned $total active configurations, $fortinet of them are Fortinet."

  # The loop runs in this shell, not in a subshell, so the counters survive it.
  local device
  while IFS= read -r device; do
    [ -z "$device" ] && continue
    sync.device "$device"
  done < <($JQ -rc '.[] | select( .manufacturer == "Fortinet" )' <<<"$configurations")

  return 0
}

# ---------------------------------------------------------- stage: report

# Organization read from IT Glue, kept for the rest of the run. The answer is
# cached in the run state and not in a variable: this function is called from
# inside command substitutions, where a variable would not survive.
report.organization() {
  local oid="$1"

  local organization
  if organization=$(system.state.get "organization.$oid"); then
    echo "$organization"
    return 0
  fi

  organization=$(itglue.organization.by.id "$oid") || organization='{}'
  system.state.set "organization.$oid" "$organization"

  echo "$organization"

  return 0
}

# report.devices <device names JSON>
#
# Maps every organization to the devices it has to report on: its own firewalls
# plus the firewalls of the organizations below it. Prints
# [ { "oid": 11, "short": "ACME", "devices": [ "ACME-HQ-FW01" ] } ].
report.devices() {
  local names="$1"

  local configurations
  configurations=$(itglue.configuration.by.name "$names") || return 1

  local known
  known=$($JQ -rc '[ .[] | { "name": .name, "oid": .oid, "short": .short } ] | unique' <<<"$configurations")

  local missing
  missing=$($JQ -nc --argjson names "$names" --argjson known "$known" \
    '[ $names[] | select( . as $n | ( $known | map( .name ) | index( $n ) ) == null ) ]')
  if [ "$($JQ -r 'length' <<<"$missing")" -ne 0 ]; then
    system.log.warning "Devices with no matching IT Glue configuration: $($JQ -rc 'join( ", " )' <<<"$missing")"
  fi

  # Walk up the parent chain of every organization, so a parent gets the reports
  # of the firewalls of its children as well.
  local assignment='[]'
  local entry oid short devices
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    oid=$($JQ -r '.oid' <<<"$entry")
    short=$($JQ -r '.short // ""' <<<"$entry")
    devices=$($JQ -rc '[ .name ]' <<<"$entry")

    local current="$oid"
    local guard=0
    while [ "$current" -gt 0 ] && [ "$guard" -lt 32 ]; do
      local organization parent name
      organization=$(report.organization "$current")
      name=$($JQ -r '.short // ""' <<<"$organization")
      if [ -z "$name" ] || [ "$name" = "null" ]; then
        if [ "$current" != "$oid" ]; then
          # An organization further up that cannot be read must not inherit the
          # short name of the one below: its reports would land in the wrong
          # folder, addressed to the wrong people.
          system.log.warning "Organization $current could not be read from IT Glue, the organizations above $short are skipped"
          break
        fi
        name="$short"
      fi

      assignment=$($JQ -nc --argjson assignment "$assignment" --argjson oid "$current" \
        --arg short "$name" --argjson devices "$devices" '
        $assignment
        | if ( map( .oid ) | index( $oid ) ) == null
          then . + [ { "oid": $oid, "short": $short, "devices": $devices } ]
          else map( if .oid == $oid then .devices = ( ( .devices + $devices ) | unique ) else . end )
          end
      ')

      parent=$($JQ -r '.parent // 0' <<<"$organization")
      system.number "$parent" || parent=0
      [ "$parent" -eq "$current" ] && break
      current="$parent"
      guard=$((guard + 1))
    done
  done < <($JQ -rc '.[]' <<<"$known")

  $JQ -rc 'map( .devices |= ( . | unique | sort ) ) | sort_by( .oid )' <<<"$assignment"

  return 0
}

# report.recipients <organization identifier>
#
# Report recipients of one organization, grouped by language:
# [ { "language": "it", "contacts": [ 9001 ] } ]. An organization that names
# nobody produces an empty list and is left alone.
report.recipients() {
  local oid="$1"

  local query
  query=$($JQ -nc --arg oid "$oid" '[ { "key": "filter[organization-id]", "value": $oid } ]') || return 1

  local assets
  assets=$(itglue.get.all itglue.flexible.get "$ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID" "$query") || return 1

  # One group per language, keeping only the groups that actually name someone.
  $JQ -rc --argjson oid "$oid" '
    [ .[] | select( .oid == $oid ) | .traits // {}
      | { "language": ( .language // "" | if type == "array" then ( .[0] // "" ) else . end | tostring | ascii_downcase ),
          "contacts": [ ( .contacts.values // [] )[] | .id | tonumber? // empty ] }
      | select( .language != "" and ( .contacts | length ) > 0 ) ]
    | group_by( .language )
    | map( { "language": .[0].language, "contacts": ( map( .contacts ) | add | unique ) } )
  ' <<<"$assets"

  return 0
}

# report.rebuild <adom> <master folder id> <organization entry> <language> <addresses JSON>
#
# Creates the new report set of one organization and one language. Prints
# { "folder": 101, "profile": "ACME-IT-...", "layouts": [ 950, 951 ] } so the
# caller can retire the previous set once every language is in place. Nothing
# is deleted here: on failure the partial work is undone and the previous
# reports survive untouched.
report.rebuild() {
  local adom="$1"
  local master="$2"
  local entry="$3"
  local language="$4"
  local addresses="$5"

  local short devices
  short=$($JQ -r '.short' <<<"$entry")
  devices=$($JQ -rc '.devices' <<<"$entry")

  local directory
  if ! directory=$(system.path.child "$FORTIANALYZER_TEMPLATE" "$language") || [ ! -d "$directory" ]; then
    system.status warning "$short ($language) @ ADOM $adom has no report template for that language"
    return 1
  fi

  local recipients
  recipients=$($JQ -nc \
    --arg from "$ENVIRONMENT_FORTIANALYZER_EMAIL_FROM" \
    --arg smtp "$ENVIRONMENT_FORTIANALYZER_EMAIL_SMTP" \
    --argjson addresses "$addresses" \
    '[ $addresses[] | { "email-from": $from, "email-server": $smtp, "address": . } ]') || return 1

  # The folder of the organization stays across runs: only its content is
  # replaced. The list is read again here because the folder may have been
  # created a moment ago, while serving another language of this organization.
  local folders folder
  folders=$(fortianalyzer.folder.list "$adom") || return 1
  folder=$(fortianalyzer.folder.search "$folders" "$short" "$master")
  if ! system.integer "$folder"; then
    system.status error "$short ($language) @ ADOM $adom folder could not be looked up"
    return 1
  fi
  if [ "$folder" -lt 0 ]; then
    if ! folder=$(fortianalyzer.folder.create "$adom" "$short" "$master"); then
      system.status error "$short ($language) @ ADOM $adom folder could not be created"
      return 1
    fi
  fi
  if ! system.number "$folder"; then
    system.status error "$short ($language) @ ADOM $adom folder identifier is not a number"
    return 1
  fi

  local mark
  mark=$(system.uuid)

  local -a created_layouts=()
  local -a created_schedules=()
  local profile=""
  local failed=0

  profile=$(fortianalyzer.output.create "$adom" "$short" "$language" "$recipients" "$mark") || failed=1

  if [ "$failed" -eq 0 ]; then
    local file template layout schedule
    while IFS= read -r file; do
      [ -z "$file" ] && continue
      template=$(basename "$file" .json)
      [ "$template" = "email" ] && continue

      if ! layout=$(fortianalyzer.layout.create "$adom" "$short" "$language" "$folder" "$template" "$mark"); then
        failed=1
        break
      fi
      created_layouts+=("$layout")

      if ! schedule=$(fortianalyzer.schedule.create "$adom" "$layout" "$profile" "$devices"); then
        failed=1
        break
      fi
      [ -n "$schedule" ] && created_schedules+=("$schedule")
    done < <(find "$directory" -maxdepth 1 -type f -name '*.json' | sort)
  fi

  if [ "$failed" -ne 0 ]; then
    system.status error "$short ($language) @ ADOM $adom rebuild failed, the previous reports are kept"
    report.discard "$adom" created_schedules created_layouts "$profile"
    return 1
  fi

  if [ ${#created_layouts[@]} -eq 0 ]; then
    system.status warning "$short ($language) @ ADOM $adom has no report template to build"
    report.discard "$adom" created_schedules created_layouts "$profile"
    return 1
  fi

  local count
  count=$($JQ -r 'length' <<<"$devices")
  system.status ok "$short ($language) @ ADOM $adom rebuilt ${#created_layouts[@]} reports over $count devices"

  $JQ -nc --argjson folder "$folder" --arg profile "$profile" --args \
    '{ "folder": $folder, "profile": $profile, "layouts": $ARGS.positional }' "${created_layouts[@]}"

  return 0
}

# report.discard <adom> <schedules array name> <layouts array name> <output profile>
# Removes what has just been created, after a failed rebuild.
report.discard() {
  local adom="$1"
  local -n schedules="$2"
  local -n layouts="$3"
  local profile="$4"

  local item
  for item in ${schedules+"${schedules[@]}"}; do
    fortianalyzer.schedule.delete "$adom" "$item" || true
  done
  for item in ${layouts+"${layouts[@]}"}; do
    fortianalyzer.layout.delete "$adom" "$item" || true
  done
  [ -n "$profile" ] && { fortianalyzer.output.delete "$adom" "$profile" || true; }

  return 0
}

# report.retire <adom> <built JSON>
#
# Removes the reports of the previous run for the organizations rebuilt in this
# one: the schedules pointing at the old layouts, those layouts, and the output
# profiles those schedules were using.
#
# Nothing is chosen by name. Several instances of this tool share one appliance,
# each one with its own parent folder, so the only safe definition of "ours" is
# "hanging from a folder we have just filled": a profile goes only when the
# schedules being removed were the ones using it and nothing else refers to it.
#
# It runs once per organization, after every language has been rebuilt: doing it
# per language would make the second language delete the reports of the first,
# because both live in the same folder.
report.retire() {
  local adom="$1"
  local built="$2"

  [ "$($JQ -r 'length' <<<"$built")" -eq 0 ] && return 0

  local layouts schedules
  if ! layouts=$(fortianalyzer.layout.list "$adom"); then
    system.log.warning "The reports of the previous run in ADOM $adom could not be listed, they stay in place"
    return 0
  fi
  if ! schedules=$(fortianalyzer.schedule.list "$adom"); then
    system.log.warning "The schedules of ADOM $adom could not be listed, the previous reports stay in place"
    return 0
  fi

  local folder
  while IFS= read -r folder; do
    [ -z "$folder" ] && continue

    local keep fresh
    keep=$($JQ -rc --argjson folder "$folder" \
      '[ .[] | select( .folder == $folder ) | .layouts[] | tostring ]' <<<"$built")
    fresh=$($JQ -rc --argjson folder "$folder" \
      '[ .[] | select( .folder == $folder ) | .profile ]' <<<"$built")

    # A layout living in more than one folder may belong to another instance as
    # well: it is reported and left alone.
    local shared
    shared=$($JQ -rc --argjson folder "$folder" \
      '[ .[] | select( ( .folders | length ) > 1 ) | select( ( .folders | index( $folder ) ) != null ) | .title ]' <<<"$layouts")
    if [ "$($JQ -r 'length' <<<"$shared")" -ne 0 ]; then
      system.log.warning "ADOM $adom holds reports shared with another folder, left untouched: $($JQ -rc 'join( ", " )' <<<"$shared")"
    fi

    local old
    old=$($JQ -rc --argjson folder "$folder" --argjson keep "$keep" '
      [ .[]
        | select( ( .folders | length ) == 1 )
        | select( ( .folders | index( $folder ) ) != null )
        | ( .id | tostring ) as $id
        | select( ( $keep | index( $id ) ) == null )
        | .id ]
    ' <<<"$layouts") || old='[]'

    [ "$($JQ -r 'length' <<<"$old")" -eq 0 ] && continue

    # Schedules pointing at the layouts being replaced, and the profiles they use.
    local doomed profiles survivors
    doomed=$($JQ -rc --argjson old "$old" '
      [ .[] | select( [ .layouts[] | select( . as $l | ( $old | index( $l ) ) != null ) ] | length > 0 ) ]
    ' <<<"$schedules")
    profiles=$($JQ -rc --argjson fresh "$fresh" '
      [ .[] | .profile | select( . != "" ) | select( . as $p | ( $fresh | index( $p ) ) == null ) ] | unique
    ' <<<"$doomed")
    survivors=$($JQ -rc --argjson doomed "$doomed" '
      ( $doomed | map( .name ) ) as $gone
      | [ .[] | .name as $name | select( ( $gone | index( $name ) ) == null ) | .profile ]
    ' <<<"$schedules")

    local name
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      fortianalyzer.schedule.delete "$adom" "$name" || system.log.warning "Schedule $name of ADOM $adom could not be deleted"
    done < <($JQ -rc '.[] | .name' <<<"$doomed")

    local id
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      fortianalyzer.layout.delete "$adom" "$id" || system.log.warning "Layout $id of ADOM $adom could not be deleted"
    done < <($JQ -rc '.[]' <<<"$old")

    # An output profile goes only when no surviving schedule still uses it.
    local target
    while IFS= read -r target; do
      [ -z "$target" ] && continue
      fortianalyzer.output.delete "$adom" "$target" || system.log.warning "Output profile $target of ADOM $adom could not be deleted"
    done < <($JQ -rc --argjson survivors "$survivors" '
      .[] | select( . as $p | ( $survivors | index( $p ) ) == null )
    ' <<<"$profiles")
  done < <($JQ -rc '[ .[].folder ] | unique | .[]' <<<"$built")

  return 0
}

# report.serve <adom> <master folder id> <organization entry>
# Every language of one organization, then the retirement of what it replaces.
report.serve() {
  local adom="$1"
  local master="$2"
  local entry="$3"

  local oid short
  oid=$($JQ -r '.oid' <<<"$entry")
  short=$($JQ -r '.short // ""' <<<"$entry")
  if [ -z "$short" ] || [ "$short" = "null" ]; then
    system.log.warning "Organization $oid has no short name in IT Glue, its reports are skipped"
    return 0
  fi

  local languages
  if ! languages=$(report.recipients "$oid"); then
    system.log.error "The report recipients of organization $short could not be read"
    return 1
  fi

  if [ "$($JQ -r 'length' <<<"$languages")" -eq 0 ]; then
    system.log.debug "Organization $short names no report recipient, nothing is touched"
    return 0
  fi

  local built='[]'
  local group language contacts addresses outcome
  while IFS= read -r group; do
    [ -z "$group" ] && continue
    language=$($JQ -r '.language' <<<"$group")
    contacts=$($JQ -rc '.contacts' <<<"$group")
    if [ "$($JQ -r 'length' <<<"$contacts")" -eq 0 ]; then
      system.status warning "$short ($language) @ ADOM $adom names recipients this tool cannot read, the previous reports are kept"
      continue
    fi

    if ! addresses=$(itglue.contact.email "$contacts" "$oid"); then
      system.status error "$short ($language) @ ADOM $adom recipients could not be read from IT Glue, the previous reports are kept"
      continue
    fi
    if [ "$($JQ -r 'length' <<<"$addresses")" -eq 0 ]; then
      system.status warning "$short ($language) @ ADOM $adom names recipients with no usable address, the previous reports are kept"
      continue
    fi

    outcome=$(report.rebuild "$adom" "$master" "$entry" "$language" "$addresses") || continue
    [ -z "$outcome" ] && continue
    built=$($JQ -nc --argjson built "$built" --argjson item "$outcome" '$built + [ $item ]')
  done < <($JQ -rc '.[]' <<<"$languages")

  # Only now, with every language of this organization in place, the previous
  # set can go: retiring per language would delete what the first language has
  # just created, since both live in the same folder.
  report.retire "$adom" "$built"

  return 0
}

# report.adom <adom>
report.adom() {
  local adom="$1"

  local folders
  if ! folders=$(fortianalyzer.folder.list "$adom"); then
    system.log.error "Report folders of ADOM $adom could not be read"
    return 1
  fi

  # The parent folder is looked for at the top level first: a folder with the
  # same name nested under another instance's tree is not ours.
  local master
  master=$(fortianalyzer.folder.search "$folders" "$ENVIRONMENT_FORTIANALYZER_FOLDER" 0)
  if ! system.integer "$master"; then
    system.log.error "The folder $ENVIRONMENT_FORTIANALYZER_FOLDER of ADOM $adom could not be looked up, nothing is touched"
    return 1
  fi
  if [ "$master" -lt 0 ]; then
    master=$(fortianalyzer.folder.search "$folders" "$ENVIRONMENT_FORTIANALYZER_FOLDER")
    system.integer "$master" || master=-1
    if [ "$master" -ge 0 ]; then
      system.log.warning "The folder $ENVIRONMENT_FORTIANALYZER_FOLDER of ADOM $adom is not at the top level, using the one found at $master"
    fi
  fi
  if [ "$master" -lt 0 ]; then
    system.log.info "ADOM $adom has no folder named $ENVIRONMENT_FORTIANALYZER_FOLDER, nothing to do."
    return 0
  fi

  local devices
  if ! devices=$(fortianalyzer.adom.devices "$adom"); then
    system.log.error "Devices of ADOM $adom could not be read"
    return 1
  fi

  local firewalls
  firewalls=$($JQ -rc --arg pattern "$WRAPPER_DEVICE_PATTERN" '[ .[] | select( test( $pattern ) ) ] | unique' <<<"$devices")
  if [ "$($JQ -r 'length' <<<"$firewalls")" -eq 0 ]; then
    system.log.info "ADOM $adom holds no device matching the naming convention, nothing to do."
    return 0
  fi

  local assignment
  if ! assignment=$(report.devices "$firewalls"); then
    system.log.error "The organizations of ADOM $adom could not be resolved"
    return 1
  fi

  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    report.serve "$adom" "$master" "$entry" || true
  done < <($JQ -rc '.[]' <<<"$assignment")

  # Folders of organizations that are no longer served are only reported: they
  # may hold work done by hand, or belong to another instance.
  local orphans
  orphans=$($JQ -rc --argjson master "$master" --argjson assignment "$assignment" '
    ( $assignment | map( .short ) ) as $served
    | [ .[] | select( ( .parent | tonumber? // 0 ) == $master )
        | .name as $name
        | select( ( $served | index( $name ) ) == null )
        | $name ]
  ' <<<"$folders")
  if [ "$($JQ -r 'length' <<<"$orphans")" -ne 0 ]; then
    system.log.warning "ADOM $adom holds report folders with no organization behind them, and whatever is scheduled inside them keeps being sent: $($JQ -rc 'join( ", " )' <<<"$orphans")"
  fi

  return 0
}

report.run() {
  system.log.info "Report generation on FortiAnalyzer."

  local adoms
  if ! adoms=$(fortianalyzer.adom.list); then
    system.log.error "The list of ADOMs could not be read, the report stage is skipped."
    return 1
  fi

  if [ -n "${ENVIRONMENT_FORTIANALYZER_ADOM:-}" ]; then
    adoms=$($JQ -rc --arg wanted "$ENVIRONMENT_FORTIANALYZER_ADOM" '
      ( $wanted | split( "," ) | map( gsub( "^\\s+|\\s+$"; "" ) ) ) as $list
      | [ .[] | select( . as $a | ( $list | index( $a ) ) != null ) ]
    ' <<<"$adoms")
    system.log.info "Working only on the ADOMs named by ENVIRONMENT_FORTIANALYZER_ADOM: $($JQ -rc 'join( ", " )' <<<"$adoms")"
  fi

  local adom
  while IFS= read -r adom; do
    [ -z "$adom" ] && continue
    report.adom "$adom" || true
  done < <($JQ -rc '.[]' <<<"$adoms")

  return 0
}

# ----------------------------------------------------------------------- main

main() {
  trap wrapper.interrupt INT QUIT TERM
  trap wrapper.finish EXIT

  wrapper.banner

  if ! system.state.setup; then
    printf 'The run state directory could not be created.\n' >&2
    exit 2
  fi

  if ! environment.validate; then
    system.log.error "The run cannot start with an incomplete configuration."
    exit 2
  fi

  itglue.setup || exit 2
  fortimanager.setup || exit 2
  fortianalyzer.setup || exit 2

  [ "$SYSTEM_DRYRUN" -eq 1 ] && system.log.info "Rehearsal mode: no call that writes will be sent."

  if ! fortianalyzer.login; then
    system.log.error "Without a FortiAnalyzer session there is nothing this run can do."
    exit 2
  fi

  if [ -z "${ENVIRONMENT_FORTINET_NOSYNC:-}" ] && ! fortimanager.login; then
    system.log.error "Without a FortiCare token the asset descriptions cannot be written."
    exit 2
  fi

  if [ -n "${ENVIRONMENT_FORTINET_NOSYNC:-}" ] && [ -n "${ENVIRONMENT_FORTIANALYZER_NORENAME:-}" ]; then
    system.log.info "Sync stage not attempted: neither FortiCare descriptions nor device names are written by this instance."
  else
    sync.run || true
  fi

  if [ -n "${ENVIRONMENT_FORTIANALYZER_NOREPORT:-}" ]; then
    system.log.info "Report stage not attempted, ENVIRONMENT_FORTIANALYZER_NOREPORT is set."
  else
    report.run || true
  fi

  system.summary

  [ "$(system.count.read error)" -gt 0 ] && exit 1

  exit 0
}

main "$@"
