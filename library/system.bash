#!/bin/bash
#
# Shared helpers: run state, event log, HTTP calls with timeouts and retries,
# outcome counters and small utilities.
#
# Rules honoured by the whole project:
#   * JSON is always built with jq, never with printf: the names coming from
#     IT Glue contain double quotes, backslashes and percent signs;
#   * no credential ever lands in a process argument (visible through ps):
#     request bodies and headers travel through files, and the values jq needs
#     are read from the environment instead of the command line;
#   * everything the run has to remember lives in files under one state
#     directory, never in shell variables: most of this code runs inside
#     command substitutions, and a variable set there dies with the subshell;
#   * every call has a deadline and a bounded number of retries: this tool runs
#     at night, with nobody around to unblock it.

JQ="${JQ:-/usr/bin/jq}"
CURL="${CURL:-/usr/bin/curl}"

# Network settings, overridable from the environment.
SYSTEM_HTTP_RETRY="${ENVIRONMENT_HTTP_RETRY:-4}"
SYSTEM_HTTP_TIMEOUT="${ENVIRONMENT_HTTP_TIMEOUT:-120}"
SYSTEM_HTTP_CONNECT_TIMEOUT="${ENVIRONMENT_HTTP_CONNECT_TIMEOUT:-15}"
SYSTEM_HTTP_BACKOFF="${ENVIRONMENT_HTTP_BACKOFF:-2}"

# Log level: debug, info, warning, error.
SYSTEM_LOG_LEVEL="${ENVIRONMENT_LOG_LEVEL:-info}"

# Rehearsal mode: when set to 1 no modifying call is ever sent.
SYSTEM_DRYRUN=0
# shellcheck disable=SC2034  # read by the other modules that are sourced later
case "${ENVIRONMENT_DRYRUN:-0}" in
1 | true | TRUE | yes | YES) SYSTEM_DRYRUN=1 ;;
esac

# Directory holding everything the run has to remember. Exported so that every
# subshell writes into the same place.
export SYSTEM_STATE="${SYSTEM_STATE:-}"

# ----------------------------------------------------------------- run state

system.state.setup() {
  [ -n "$SYSTEM_STATE" ] && return 0

  SYSTEM_STATE=$(mktemp -d "${TMPDIR:-/tmp}/fortiglue.XXXXXXXX") || return 1
  chmod 700 "$SYSTEM_STATE"
  mkdir -p "$SYSTEM_STATE/counter" "$SYSTEM_STATE/cache" "$SYSTEM_STATE/clock" || return 1
  export SYSTEM_STATE

  return 0
}

# Removes the state directory: request bodies, authentication headers and the
# appliance session live in there.
system.cleanup() {
  [ -z "$SYSTEM_STATE" ] && return 0

  rm -rf "$SYSTEM_STATE"
  SYSTEM_STATE=""

  return 0
}

# Temporary file with tight permissions, removed together with the state.
system.temporary() {
  local file
  if [ -n "$SYSTEM_STATE" ]; then
    file=$(mktemp "$SYSTEM_STATE/work.XXXXXXXX") || return 1
  else
    file=$(mktemp "${TMPDIR:-/tmp}/fortiglue.XXXXXXXX") || return 1
  fi
  chmod 600 "$file"

  echo "$file"

  return 0
}

# A value kept for the whole run, readable and writable from any subshell.
system.state.set() {
  [ -z "$SYSTEM_STATE" ] && return 0

  printf '%s' "$2" >"$SYSTEM_STATE/cache/$1"

  return 0
}

system.state.get() {
  [ -z "$SYSTEM_STATE" ] && return 1
  [ -f "$SYSTEM_STATE/cache/$1" ] || return 1

  cat "$SYSTEM_STATE/cache/$1"

  return 0
}

# ------------------------------------------------------------------------ log

system.timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Level ordering, used to decide what gets printed.
system.log.weight() {
  case "$1" in
  debug) echo 10 ;;
  info) echo 20 ;;
  warning) echo 30 ;;
  error) echo 40 ;;
  *) echo 20 ;;
  esac
}

system.log() {
  local level="$1"
  shift

  local wanted current
  wanted=$(system.log.weight "$SYSTEM_LOG_LEVEL")
  current=$(system.log.weight "$level")
  [ "$current" -lt "$wanted" ] && return 0

  # Two rules here. The message is never used as a format string: a name
  # holding a percent sign must not be able to break the output. And the log
  # goes to standard error, because standard output carries the values the
  # functions return: a log line landing there would be read as an identifier.
  printf '%s %-7s %s\n' "$(system.timestamp)" "$level" "$*" >&2

  return 0
}

# One event of the given kind. Counting happens in a file because most of these
# calls are made inside a command substitution, where a variable would not
# survive; the exit code of the run is decided on these numbers.
system.count() {
  [ -z "$SYSTEM_STATE" ] && return 0

  printf '.' >>"$SYSTEM_STATE/counter/$1" 2>/dev/null

  return 0
}

system.count.read() {
  local file="${SYSTEM_STATE:-}/counter/$1"
  if [ -z "$SYSTEM_STATE" ] || [ ! -f "$file" ]; then
    echo 0
    return 0
  fi

  local size
  size=$(wc -c <"$file" 2>/dev/null | tr -d ' ')
  system.number "$size" || size=0

  echo "$size"

  return 0
}

system.log.debug() { system.log debug "$@"; }
system.log.info() { system.log info "$@"; }

system.log.warning() {
  system.count warning
  system.log warning "$@"
}

system.log.error() {
  system.count error
  system.log error "$@"
}

# Outcome of a single unit of work:
#   2026-09-21T02:10:04Z info    [ACME-HQ-FW01] - Acme S.p.A. @ FortiAnalyzer [Ok]
system.status() {
  local outcome="$1"
  shift

  case "$outcome" in
  ok)
    system.count ok
    system.log info "$* [Ok]"
    ;;
  skip)
    system.count skip
    system.log info "$* [--]"
    ;;
  warning)
    system.count warning
    system.log warning "$* [!]"
    ;;
  *)
    system.count error
    system.log error "$* [!!]"
    ;;
  esac

  return 0
}

# What a rehearsal would have changed. It is printed as an ordinary message: a
# rehearsal that says nothing about what it would delete would be useless.
system.rehearsal() {
  system.log info "rehearsal: $*"

  return 0
}

# Closing summary: the only line that matters when the log is read next morning.
system.summary() {
  system.log info "Summary: $(system.count.read ok) done, $(system.count.read skip) skipped, $(system.count.read warning) warnings, $(system.count.read error) errors."

  return 0
}

# ------------------------------------------------------------------ utilities

# Unique identifier: the kernel always provides one, with no dependency on uuidgen.
system.uuid() {
  local uuid=""
  if [ -r /proc/sys/kernel/random/uuid ]; then
    read -r uuid </proc/sys/kernel/random/uuid
  fi
  if [ -z "$uuid" ] && command -v uuidgen >/dev/null 2>&1; then
    uuid=$(uuidgen)
  fi
  if [ -z "$uuid" ]; then
    uuid=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  fi

  echo "$uuid" | tr '[:lower:]' '[:upper:]'

  return 0
}

# True when the string is a non negative integer.
system.number() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# True when the string is an integer, a leading minus allowed. Identifiers are
# checked with this before any numeric test: an empty value would make the test
# itself fail, and a failing guard lets the caller walk straight into the part
# that deletes things.
system.integer() {
  [[ "$1" =~ ^-?[0-9]+$ ]]
}

# True when the given text is valid JSON.
system.json.valid() {
  $JQ -e . >/dev/null 2>&1 <<<"$1"
}

# True when the given text is a JSON object.
system.json.object() {
  [ "$($JQ -r 'type' <<<"$1" 2>/dev/null)" = "object" ]
}

# True when the tag list (JSON array, comma separated string or null) holds the
# wanted tag. The comparison ignores case and padding: in IT Glue those tags are
# typed by hand.
system.tag.contains() {
  local tags="$1"
  local wanted="$2"

  local found
  found=$($JQ -r --arg wanted "$wanted" '
    def normalize(x): x | ascii_downcase | gsub( "^\\s+|\\s+$"; "" );
    ( if type == "array" then . elif type == "string" then split( "," ) else [] end )
    | map( select( type == "string" ) | normalize( . ) )
    | if index( normalize( $wanted ) ) then "1" else "0" end
  ' <<<"$tags" 2>/dev/null) || found=0

  [ "$found" = "1" ]
}

# Path of a file inside a directory, with no way out of it: the language comes
# from IT Glue and must not be able to become "../../etc".
system.path.child() {
  local base="$1"
  local name="$2"

  case "$name" in
  "" | . | .. | */* | *\\*) return 1 ;;
  esac

  echo "$base/$name"

  return 0
}

# Turns a JSON list of key/value pairs into an encoded query string:
# [ { "key": "page[size]", "value": 600 } ] -> page%5Bsize%5D=600
system.querystring() {
  $JQ -rc '
    def convert(x): ( x | tostring ) | @uri;
    [ .[] | select( .value != null ) | convert( .key ) + "=" + convert( .value ) ] | join( "&" )
  ' <<<"$1"

  return 0
}

# Full address of a service: accepts both "host" and "https://host", so the same
# code works in production and on the test bench.
system.endpoint() {
  local value="$1"

  case "$value" in
  http://* | https://*) echo "${value%/}" ;;
  *) echo "https://${value%/}" ;;
  esac

  return 0
}

# Minimum pause between two calls to the same service, to stay inside its rate
# limit. The moment of the last call is kept in a file, so the pause works even
# when the caller runs inside a command substitution.
system.throttle() {
  local name="$1"
  local minimum="$2"

  [ "$minimum" = "0" ] && return 0
  [ -z "$SYSTEM_STATE" ] && return 0

  local file="$SYSTEM_STATE/clock/$name"
  local now="${EPOCHREALTIME/,/.}"

  if [ -f "$file" ]; then
    local last wait
    last=$(cat "$file" 2>/dev/null)
    if [ -n "$last" ]; then
      wait=$(awk -v now="$now" -v last="$last" -v minimum="$minimum" \
        'BEGIN { delta = minimum - ( now - last ); if ( delta > 0 ) printf "%.3f", delta; else print "0" }')
      [ "$wait" != "0" ] && sleep "$wait"
    fi
  fi

  printf '%s' "${EPOCHREALTIME/,/.}" >"$file"

  return 0
}

# -------------------------------------------------------------------- network

# Turns the curl exit status into a readable reason.
system.request.reason() {
  case "$1" in
  6) echo "host not resolved" ;;
  7) echo "connection refused" ;;
  28) echo "deadline exceeded" ;;
  35 | 60) echo "TLS error" ;;
  52) echo "empty reply" ;;
  56) echo "connection reset" ;;
  *) echo "curl error $1" ;;
  esac
}

# One "header" line for a curl configuration file, with the value escaped:
# a credential holding a quote or a backslash must not break the file.
system.request.header() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"

  printf 'header = "%s"\n' "$value"

  return 0
}

# system.request <method> <url> <body-file|""> [curl-config-file] [extra curl options...]
#
# Prints the response body on standard output. Returns 0 when the status is 2xx,
# 1 otherwise. Retries network errors, 429 and 5xx with a growing pause, and
# honours Retry-After when the server sends it.
#
# Calls that create something are retried as well: a lost answer can leave an
# object behind on the appliance, and that object is then removed by the very
# next run, because it hangs from a folder this tool owns and is not among the
# ones just created.
system.request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local config="${4:-}"
  shift 4 2>/dev/null || shift $#

  local -a options=("$@")
  local response headers error attempt=1 code=0 status=0

  response=$(system.temporary) || return 1
  headers=$(system.temporary) || return 1
  error=$(system.temporary) || return 1

  while :; do
    : >"$response"
    : >"$headers"
    : >"$error"

    local -a command=(
      "$CURL" --silent --show-error --compressed
      --connect-timeout "$SYSTEM_HTTP_CONNECT_TIMEOUT"
      --max-time "$SYSTEM_HTTP_TIMEOUT"
      --request "$method"
      --dump-header "$headers"
      --output "$response"
      --write-out '%{http_code}'
    )
    [ -n "$config" ] && command+=(--config "$config")
    [ -n "$body" ] && command+=(--data-binary "@$body")
    [ ${#options[@]} -gt 0 ] && command+=("${options[@]}")
    command+=("$url")

    # The assignment must never abort the script: the outcome is handled here.
    status=0
    code=$("${command[@]}" 2>"$error") || status=$?
    system.number "$code" || code=0

    if [ "$status" -eq 0 ] && [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
      cat "$response"
      return 0
    fi

    local reason
    if [ "$status" -ne 0 ]; then
      reason="$(system.request.reason "$status") ($(tr -d '\n' <"$error" | head -c 200))"
    else
      reason="status $code"
    fi

    # A 4xx other than 408 and 429 will not get better by trying again.
    if [ "$status" -eq 0 ] && [ "$code" -ge 400 ] && [ "$code" -lt 500 ] &&
      [ "$code" -ne 429 ] && [ "$code" -ne 408 ]; then
      system.log.debug "$method $url: $reason, body: $(head -c 400 "$response" | tr -d '\n')"
      cat "$response"
      return 1
    fi

    if [ "$attempt" -ge "$SYSTEM_HTTP_RETRY" ]; then
      system.log.debug "$method $url: $reason, giving up after $SYSTEM_HTTP_RETRY attempts"
      cat "$response"
      return 1
    fi

    # Retry-After wins over the computed pause.
    local wait=$((SYSTEM_HTTP_BACKOFF ** attempt))
    local after
    after=$(grep -i '^retry-after:' "$headers" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')
    system.number "$after" && wait="$after"
    [ "$wait" -gt 60 ] && wait=60

    system.log.debug "$method $url: $reason, retrying in ${wait}s ($attempt/$SYSTEM_HTTP_RETRY)"
    sleep "$wait"
    attempt=$((attempt + 1))
  done
}

# Writes a JSON value into a temporary file and prints its path: this is how
# request bodies reach curl without being exposed in the process arguments.
system.request.body() {
  local file
  file=$(system.temporary) || return 1
  printf '%s' "$1" >"$file"

  echo "$file"

  return 0
}
