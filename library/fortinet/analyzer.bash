#!/bin/bash
#
# FortiAnalyzer client (JSON-RPC).
#
# Two jobs: renaming devices after IT Glue, and keeping the scheduled reports of
# every organization up to date.
#
# Notes that shape this code:
#   * /dvmdb answers with "result" as an array, /report with apiver 3 answers
#     with "result" as an object: both shapes are normalised in one place;
#   * a session can expire in the middle of a long run; code -11 triggers one
#     sign in again and one retry, instead of a silent stream of failures;
#   * nothing is ever deleted before its replacement exists.

. /library/system.bash

FORTIANALYZER_ENDPOINT=""
FORTIANALYZER_TEMPLATE="${FORTIANALYZER_TEMPLATE:-/library/fortinet/template}"

# Appliances usually carry a self signed certificate: verification stays off by
# default, but it can be turned on by giving a certificate authority bundle.
FORTIANALYZER_RATE="${ENVIRONMENT_FORTIANALYZER_RATE:-0}"
FORTIANALYZER_TLS=(--insecure)

# The session is kept in the run state and not in a variable: a renewal happens
# inside a command substitution, and a variable set there would die with it,
# leaving every later call to open yet another administrative session.
fortianalyzer.session() {
  system.state.get fortianalyzer.session 2>/dev/null || true
}

# Environment variables owned by this module: name|requirement|description.
fortianalyzer.environment() {
  cat <<'VARIABLES'
ENVIRONMENT_FORTIANALYZER_FQDN|required|FQDN of the FortiAnalyzer appliance
ENVIRONMENT_FORTIANALYZER_USERNAME|required|FortiAnalyzer account with read and write on the API
ENVIRONMENT_FORTIANALYZER_PASSWORD|required|Password of the FortiAnalyzer account
ENVIRONMENT_FORTIANALYZER_FOLDER|required|Name of the parent report folder holding one subfolder per organization
ENVIRONMENT_FORTIANALYZER_EMAIL_FROM|required|Sender address of the report messages
ENVIRONMENT_FORTIANALYZER_EMAIL_SMTP|required|Mail server profile configured on FortiAnalyzer
ENVIRONMENT_FORTIANALYZER_ADOM|optional|Comma separated list of ADOMs to work on, default every ADOM
ENVIRONMENT_FORTIANALYZER_OVERLOAD|json|JSON object merged into every report layout
ENVIRONMENT_FORTIANALYZER_NOREPORT|flag|When set, the report stage is not executed
ENVIRONMENT_FORTIANALYZER_NORENAME|flag|When set, devices are not renamed on this appliance
ENVIRONMENT_FORTIANALYZER_CACERT|optional|Path of a certificate authority bundle enabling TLS verification
ENVIRONMENT_FORTIANALYZER_RATE|optional|Minimum seconds between two FortiAnalyzer calls, default 0
VARIABLES
}

fortianalyzer.setup() {
  FORTIANALYZER_ENDPOINT=$(system.endpoint "$ENVIRONMENT_FORTIANALYZER_FQDN")

  if [ -n "${ENVIRONMENT_FORTIANALYZER_CACERT:-}" ]; then
    if [ ! -r "$ENVIRONMENT_FORTIANALYZER_CACERT" ]; then
      system.log.error "The certificate authority bundle $ENVIRONMENT_FORTIANALYZER_CACERT cannot be read"
      return 1
    fi
    FORTIANALYZER_TLS=(--cacert "$ENVIRONMENT_FORTIANALYZER_CACERT")
    system.log.debug "FortiAnalyzer certificate verification is on"
  else
    FORTIANALYZER_TLS=(--insecure)
    system.log.debug "FortiAnalyzer certificate verification is off"
  fi

  system.log.debug "FortiAnalyzer endpoint $FORTIANALYZER_ENDPOINT"

  return 0
}

# fortianalyzer.send <request JSON>
# One transport level call, without any session handling.
fortianalyzer.send() {
  local file
  file=$(system.request.body "$1") || return 1

  system.throttle fortianalyzer "$FORTIANALYZER_RATE"

  system.request POST "$FORTIANALYZER_ENDPOINT/jsonrpc" "$file" "" \
    --header "Content-Type: application/json" "${FORTIANALYZER_TLS[@]}"
}

# fortianalyzer.call <method> <url> [parameters JSON] [apiver]
#
# Prints the "data" member of the answer. Returns 0 on success, 1 on failure,
# and logs the reason. Both answer shapes of the appliance are handled here.
fortianalyzer.call() {
  local method="$1"
  local url="$2"
  local parameters="${3:-}"
  local apiver="${4:-}"
  [ -z "$parameters" ] && parameters='{}'
  local retried="${5:-0}"

  local request
  request=$($JQ -nc \
    --arg method "$method" \
    --arg url "$url" \
    --arg session "$(fortianalyzer.session)" \
    --argjson parameters "$parameters" \
    --arg apiver "$apiver" '
    { "id": 1, "method": $method, "session": $session,
      "params": [ ( $parameters + { "url": $url } + ( if $apiver == "" then {} else { "apiver": ( $apiver | tonumber ) } end ) ) ] }
    | if $apiver == "" then . else . + { "jsonrpc": "2.0" } end
  ') || return 1

  local response
  if ! response=$(fortianalyzer.send "$request"); then
    system.log.error "FortiAnalyzer $method $url: the appliance did not answer"
    return 1
  fi

  if ! system.json.valid "$response"; then
    system.log.error "FortiAnalyzer $method $url: answer is not JSON"
    return 1
  fi

  if [ "$($JQ -r 'has( "result" )' <<<"$response" 2>/dev/null)" != "true" ]; then
    local failure
    failure=$($JQ -rc 'try( .error.message // .error ) // empty' <<<"$response" 2>/dev/null)
    system.log.error "FortiAnalyzer $method $url: the answer carries no result${failure:+: $failure}"
    return 1
  fi

  local code
  code=$($JQ -rc '( .result | if type == "array" then .[0] else . end ) | .status.code // 0' <<<"$response")
  system.number "${code#-}" || code=0

  if [ "$code" -eq 0 ]; then
    $JQ -rc '( .result | if type == "array" then .[0] else . end ) | .data // null' <<<"$response"
    return 0
  fi

  # -11 is what the appliance answers once the session is gone.
  if [ "$code" -eq -11 ] && [ "$retried" -eq 0 ]; then
    system.log.warning "FortiAnalyzer session expired, signing in again"
    if fortianalyzer.login; then
      fortianalyzer.call "$method" "$url" "$parameters" "$apiver" 1
      return $?
    fi
    return 1
  fi

  local message
  message=$($JQ -rc '( .result | if type == "array" then .[0] else . end ) | .status.message // empty' <<<"$response")
  system.log.error "FortiAnalyzer $method $url refused with code $code${message:+: $message}"

  return 1
}

fortianalyzer.login() {
  # The credentials are read by jq from its own environment: as arguments they
  # would show up in the process list of the container.
  local request
  request=$($JQ -nc '
    { "id": 1, "method": "exec",
      "params": [ { "data": { "user": env.ENVIRONMENT_FORTIANALYZER_USERNAME,
                              "passwd": env.ENVIRONMENT_FORTIANALYZER_PASSWORD },
                    "url": "/sys/login/user" } ] }
  ') || return 1

  local response
  if ! response=$(fortianalyzer.send "$request"); then
    system.log.error "FortiAnalyzer sign in: the appliance did not answer"
    return 1
  fi

  local session
  session=$($JQ -rc '.session // empty' <<<"$response" 2>/dev/null)
  if [ -z "$session" ] || [ "$session" = "null" ]; then
    local message
    message=$($JQ -rc 'try( .result[0].status.message ) // empty' <<<"$response" 2>/dev/null)
    system.log.error "FortiAnalyzer sign in failed${message:+: $message}"
    return 1
  fi

  system.state.set fortianalyzer.session "$session"
  system.log.info "FortiAnalyzer sign in done"

  return 0
}

# Closing the session frees the administrative slot on the appliance.
fortianalyzer.logout() {
  local session
  session=$(fortianalyzer.session)
  [ -z "$session" ] && return 0

  local request
  request=$($JQ -nc --arg session "$session" '
    { "id": 1, "method": "exec", "session": $session, "params": [ { "url": "/sys/logout" } ] }
  ') || return 0

  # This runs from the exit handler: a failure here must not replace the exit
  # code of the run, nor stop the cleanup that follows.
  fortianalyzer.send "$request" >/dev/null 2>&1 || true
  system.state.set fortianalyzer.session ""

  return 0
}

# ------------------------------------------------------------------ devices

# List of the ADOM names.
fortianalyzer.adom.list() {
  local data
  data=$(fortianalyzer.call get /dvmdb/adom) || return 1

  $JQ -rc '[ .[]? | .name | select( type == "string" ) ]' <<<"$data"

  return 0
}

# fortianalyzer.adom.devices <adom>
fortianalyzer.adom.devices() {
  local data
  data=$(fortianalyzer.call get "/dvmdb/adom/$1/device") || return 1

  $JQ -rc '[ .[]? | .name | select( type == "string" ) ]' <<<"$data"

  return 0
}

# fortianalyzer.device.search <serial number>
# Prints the current name of the device, or nothing when the appliance does not
# know that serial number.
fortianalyzer.device.search() {
  local parameters
  parameters=$($JQ -nc --arg serial "$1" '{ "filter": [ [ "sn", "==", $serial ] ] }') || return 1

  local data
  data=$(fortianalyzer.call get /dvmdb/device "$parameters") || return 1

  $JQ -rc '( .[0]?.name // "" )' <<<"$data"

  return 0
}

# fortianalyzer.device.rename <device JSON>
#
# Returns:
#   0 renamed (or nothing to do in rehearsal mode)
#   2 skipped on purpose (nofaz tag, not a firewall, no address, no serial)
#   1 failed
fortianalyzer.device.rename() {
  local device="$1"

  local tag type ip serial name organization
  tag=$($JQ -rc '.tag' <<<"$device")
  type=$($JQ -rc '.type // "" | tostring' <<<"$device")
  ip=$($JQ -rc '.ip // "" | tostring' <<<"$device")
  serial=$($JQ -rc '.serial // "" | tostring' <<<"$device")
  name=$($JQ -rc '.name // "" | tostring' <<<"$device")
  organization=$($JQ -rc '.organization // "" | tostring' <<<"$device")

  if [ -n "${ENVIRONMENT_FORTIANALYZER_NORENAME:-}" ]; then
    return 2
  fi
  if system.tag.contains "$tag" nofaz; then
    return 2
  fi
  if [ "$type" != "Firewall" ] || [ -z "$ip" ] || [ "$ip" = "null" ]; then
    return 2
  fi
  if [ -z "$serial" ] || [ "$serial" = "null" ] || [ -z "$name" ]; then
    return 2
  fi

  local previous
  previous=$(fortianalyzer.device.search "$serial") || return 1
  if [ -z "$previous" ]; then
    system.log.warning "Serial number $serial ($name) is unknown to FortiAnalyzer"
    return 2
  fi

  # Nothing to write when the appliance already agrees with IT Glue.
  if [ "$previous" = "$name" ]; then
    return 0
  fi

  if [ "$SYSTEM_DRYRUN" -eq 1 ]; then
    system.rehearsal "FortiAnalyzer device $previous would be renamed to $name"
    return 0
  fi

  local parameters
  parameters=$($JQ -nc --arg name "$name" --arg description "$organization" \
    '{ "data": { "name": $name, "desc": $description } }') || return 1

  fortianalyzer.call set "/dvmdb/device/$previous" "$parameters" >/dev/null || return 1

  return 0
}

# ------------------------------------------------------------------ folders

# fortianalyzer.folder.list <adom>
fortianalyzer.folder.list() {
  local data
  data=$(fortianalyzer.call get "/report/adom/$1/config/layout-folder" '{}' 3) || return 1

  $JQ -rc '[ .[]? | { "id": .["folder-id"], "name": .["folder-name"], "parent": ( .["parent-id"] // 0 ) } ]' <<<"$data"

  return 0
}

# fortianalyzer.folder.search <folder list JSON> <name> [parent id]
# Prints the identifier, or -1 when there is no such folder.
fortianalyzer.folder.search() {
  $JQ -rc --arg name "$2" --argjson parent "${3:-null}" '
    [ .[] | select( .name == $name ) | select( $parent == null or ( .parent | tonumber? // 0 ) == $parent ) | .id ]
    | first // -1
  ' <<<"$1"

  return 0
}

# fortianalyzer.folder.create <adom> <name> <parent id>
fortianalyzer.folder.create() {
  if [ "$SYSTEM_DRYRUN" -eq 1 ]; then
    system.rehearsal "folder $2 would be created in ADOM $1"
    echo 0
    return 0
  fi

  local parameters
  parameters=$($JQ -nc --arg name "$2" --argjson parent "$3" \
    '{ "data": { "folder-name": $name, "parent-id": $parent } }') || return 1

  local data
  data=$(fortianalyzer.call add "/report/adom/$1/config/layout-folder" "$parameters" 3) || return 1

  local id
  id=$($JQ -rc '.["folder-id"] // -1' <<<"$data")
  if ! system.number "$id" || [ "$id" -le 0 ]; then
    system.log.error "FortiAnalyzer did not return an identifier for the folder $2 of ADOM $1"
    return 1
  fi

  echo "$id"

  return 0
}

# There is deliberately no folder.delete here. A folder can hold work done by
# hand, and on a shared appliance it can belong to another instance of this
# tool: folders of organizations that are no longer served are reported in the
# log and left for an engineer to remove.

# ------------------------------------------------------------------ layouts

# fortianalyzer.layout.list <adom>
fortianalyzer.layout.list() {
  local data
  data=$(fortianalyzer.call get "/report/adom/$1/config/layout" '{}' 3) || return 1

  $JQ -rc '[ .[]? | { "id": .["layout-id"], "title": .title, "folders": [ ( .folders // [] )[] | .["folder-id"] ] } ]' <<<"$data"

  return 0
}

# fortianalyzer.layout.create <adom> <short name> <language> <folder id> <template> <unique mark>
# Prints the identifier of the new layout.
fortianalyzer.layout.create() {
  local adom="$1"
  local short="$2"
  local language="$3"
  local folder="$4"
  local template="$5"
  local mark="$6"

  local directory file
  directory=$(system.path.child "$FORTIANALYZER_TEMPLATE" "$language") || return 1
  file=$(system.path.child "$directory" "$template.json") || return 1
  if [ ! -r "$file" ]; then
    system.log.error "Report template $language/$template.json is missing"
    return 1
  fi

  # An operator can decorate every layout through one JSON object, for instance
  # to change the cover page of a specific installation. It is merged first, so
  # it can never move a report into another folder or rename it.
  local overload='{}'
  if [ -n "${ENVIRONMENT_FORTIANALYZER_OVERLOAD:-}" ]; then
    if ! system.json.object "$ENVIRONMENT_FORTIANALYZER_OVERLOAD"; then
      system.log.error "ENVIRONMENT_FORTIANALYZER_OVERLOAD is not a JSON object, it is ignored"
    else
      overload="$ENVIRONMENT_FORTIANALYZER_OVERLOAD"
    fi
  fi

  local layout
  layout=$($JQ -rc \
    --arg language "$language" \
    --arg short "$short" \
    --arg mark "$mark" \
    --argjson folder "$folder" \
    --argjson overload "$overload" '
    . + $overload
    | .language = $language
    | .title = ( ( $short | ascii_upcase ) + "-" + ( $language | ascii_upcase ) + "-" + ( $mark | ascii_upcase ) + "-" + ( .title | tostring ) )
    | .folders = [ { "folder-id": $folder } ]
  ' "$file") || return 1

  if [ "$SYSTEM_DRYRUN" -eq 1 ]; then
    system.rehearsal "layout $($JQ -rc '.title' <<<"$layout") would be created in ADOM $adom"
    echo 0
    return 0
  fi

  local parameters
  parameters=$($JQ -nc --argjson layout "$layout" '{ "data": $layout }') || return 1

  local data
  data=$(fortianalyzer.call add "/report/adom/$adom/config/layout" "$parameters" 3) || return 1

  local id
  id=$($JQ -rc '.["layout-id"] // -1' <<<"$data")
  if ! system.number "$id" || [ "$id" -le 0 ]; then
    system.log.error "FortiAnalyzer did not return an identifier for the layout $template ($short-$language)"
    return 1
  fi

  echo "$id"

  return 0
}

# fortianalyzer.layout.delete <adom> <layout id>
fortianalyzer.layout.delete() {
  if [ "$SYSTEM_DRYRUN" -eq 1 ]; then
    system.rehearsal "layout $2 of ADOM $1 would be deleted"
    return 0
  fi

  fortianalyzer.call delete "/report/adom/$1/config/layout/$2" '{}' 3 >/dev/null
}

# ---------------------------------------------------------------- schedules

# fortianalyzer.schedule.list <adom>
fortianalyzer.schedule.list() {
  local data
  data=$(fortianalyzer.call get "/report/adom/$1/config/schedule" '{}' 3) || return 1

  $JQ -rc '[ .[]? | { "name": ( .name | tostring ),
                      "profile": ( .["output-profile"] // "" | tostring ),
                      "layouts": [ ( .["report-layout"] // [] )[] | .["layout-id"] ] } ]' <<<"$data"

  return 0
}

# fortianalyzer.schedule.create <adom> <layout id> <output profile> <device names JSON>
fortianalyzer.schedule.create() {
  local adom="$1"
  local layout="$2"
  local profile="$3"
  local devices="$4"

  local template="$FORTIANALYZER_TEMPLATE/schedule.json"
  if [ ! -r "$template" ]; then
    system.log.error "Schedule template schedule.json is missing"
    return 1
  fi

  local schedule
  schedule=$($JQ -rc \
    --arg name "$layout" \
    --arg profile "$profile" \
    --argjson layout "$layout" \
    --argjson devices "$devices" '
    . + { "name": ( $name | ascii_upcase ),
          "output-profile": $profile,
          "report-layout": [ { "layout-id": $layout } ],
          "devices": [ { "interfaces": null, "devices-name": $devices[] } ] }
  ' "$template") || return 1

  if [ "$SYSTEM_DRYRUN" -eq 1 ]; then
    system.rehearsal "schedule $layout would be created in ADOM $adom for profile $profile"
    echo "$layout"
    return 0
  fi

  local parameters
  parameters=$($JQ -nc --argjson schedule "$schedule" '{ "data": $schedule }') || return 1

  local data
  data=$(fortianalyzer.call add "/report/adom/$adom/config/schedule" "$parameters" 3) || return 1

  # The name we asked for is the fallback: without it a schedule created by an
  # appliance that does not echo the name could not be rolled back.
  local name
  name=$($JQ -rc --arg name "$layout" '.name // $name | tostring' <<<"$data")
  [ -z "$name" ] && name="$layout"

  echo "$name"

  return 0
}

# fortianalyzer.schedule.delete <adom> <schedule name>
fortianalyzer.schedule.delete() {
  if [ "$SYSTEM_DRYRUN" -eq 1 ]; then
    system.rehearsal "schedule $2 of ADOM $1 would be deleted"
    return 0
  fi

  fortianalyzer.call delete "/report/adom/$1/config/schedule/$2" '{}' 3 >/dev/null
}

# ------------------------------------------------------------------ outputs

# fortianalyzer.output.list <adom>
fortianalyzer.output.list() {
  local data
  data=$(fortianalyzer.call get "/report/adom/$1/config/output" '{}' 3) || return 1

  $JQ -rc '[ .[]? | .name | select( type == "string" ) ]' <<<"$data"

  return 0
}

# fortianalyzer.output.create <adom> <short name> <language> <recipients JSON> <unique mark>
# Prints the name of the new output profile.
fortianalyzer.output.create() {
  local adom="$1"
  local short="$2"
  local language="$3"
  local recipients="$4"
  local mark="$5"

  local directory file
  directory=$(system.path.child "$FORTIANALYZER_TEMPLATE" "$language") || return 1
  file=$(system.path.child "$directory" "email.json") || return 1
  if [ ! -r "$file" ]; then
    system.log.error "Mail template $language/email.json is missing"
    return 1
  fi

  # The name of a profile ends up inside the url of the call that deletes it,
  # so anything outside a safe alphabet is folded away first.
  local name
  name=$($JQ -rn --arg short "$short" --arg language "$language" --arg mark "$mark" '
    def safe(x): x | ascii_upcase | gsub( "[^A-Z0-9._-]"; "-" );
    safe( $short ) + "-" + safe( $language ) + "-" + safe( $mark )
  ') || return 1

  local output
  output=$($JQ -rc --arg name "$name" --argjson recipients "$recipients" '
    { "email": 1, "email-attachment-compress": 0, "email-recipients": $recipients, "name": $name } * .
    | .name = $name
    | .["email-recipients"] = $recipients
  ' "$file") || return 1

  if [ "$SYSTEM_DRYRUN" -eq 1 ]; then
    system.rehearsal "output profile $name would be created in ADOM $adom for $($JQ -rc '[ .[].address ] | join( ", " )' <<<"$recipients")"
    echo "$name"
    return 0
  fi

  local parameters
  parameters=$($JQ -nc --argjson output "$output" '{ "data": $output }') || return 1

  local data
  data=$(fortianalyzer.call add "/report/adom/$adom/config/output" "$parameters" 3) || return 1

  $JQ -rc --arg name "$name" '.name // $name' <<<"$data"

  return 0
}

# fortianalyzer.output.delete <adom> <output name>
fortianalyzer.output.delete() {
  if [ "$SYSTEM_DRYRUN" -eq 1 ]; then
    system.rehearsal "output profile $2 of ADOM $1 would be deleted"
    return 0
  fi

  fortianalyzer.call delete "/report/adom/$1/config/output/$2" '{}' 3 >/dev/null
}
