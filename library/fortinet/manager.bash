#!/bin/bash
#
# FortiCare client (the asset registration service behind FortiManager).
#
# It is used for one thing only: writing on every Fortinet asset the description
# "[device name] - organization", taken from IT Glue.
#
# The access token lives in a curl configuration file and is renewed before it
# expires: a nightly run over hundreds of devices easily outlives one hour.

. /library/system.bash

FORTICARE_AUTH_ENDPOINT=""
FORTICARE_ENDPOINT=""
FORTICARE_CONFIG=""

# Seconds left on the token below which it gets renewed.
FORTICARE_RENEW_MARGIN=120

# Minimum pause between two calls, the service is not generous with bursts.
FORTICARE_RATE="${ENVIRONMENT_FORTINET_RATE:-0.2}"

# Environment variables owned by this module: name|requirement|description.
fortimanager.environment() {
  cat <<'VARIABLES'
ENVIRONMENT_FORTINET_USERNAME|required|FortiCare API account user name
ENVIRONMENT_FORTINET_PASSWORD|required|FortiCare API account password
ENVIRONMENT_FORTINET_CLIENTID|required|FortiCare client identifier, for example assetmanagement
ENVIRONMENT_FORTINET_NOSYNC|flag|When set, asset descriptions are not written on FortiCare
ENVIRONMENT_FORTINET_RATE|optional|Minimum seconds between two FortiCare calls, default 0.2
ENVIRONMENT_FORTICARE_ENDPOINT|optional|Base address of the FortiCare API, default https://support.fortinet.com
ENVIRONMENT_FORTICARE_AUTH_ENDPOINT|optional|Base address of the token service, default https://customerapiauth.fortinet.com
VARIABLES
}

fortimanager.setup() {
  FORTICARE_ENDPOINT=$(system.endpoint "${ENVIRONMENT_FORTICARE_ENDPOINT:-https://support.fortinet.com}")
  FORTICARE_AUTH_ENDPOINT=$(system.endpoint "${ENVIRONMENT_FORTICARE_AUTH_ENDPOINT:-https://customerapiauth.fortinet.com}")
  FORTICARE_CONFIG=$(system.temporary) || return 1

  system.log.debug "FortiCare endpoint $FORTICARE_ENDPOINT"

  return 0
}

# Asks for an access token and stores it in the curl configuration file.
fortimanager.login() {
  # The credentials are read by jq from its own environment: as arguments they
  # would show up in the process list of the container.
  local body
  body=$($JQ -nc '
    { "username": env.ENVIRONMENT_FORTINET_USERNAME,
      "password": env.ENVIRONMENT_FORTINET_PASSWORD,
      "client_id": env.ENVIRONMENT_FORTINET_CLIENTID,
      "grant_type": "password" }
  ') || return 1

  local file
  file=$(system.request.body "$body") || return 1

  local response
  if ! response=$(system.request POST "$FORTICARE_AUTH_ENDPOINT/api/v1/oauth/token/" "$file" "" \
    --header "Content-Type: application/json"); then
    local detail
    detail=$($JQ -rc 'try( .error_description // .message // .error ) // empty' <<<"$response" 2>/dev/null)
    system.log.error "FortiCare sign in failed${detail:+: $detail}"
    return 1
  fi

  local token
  token=$($JQ -rc '.access_token // empty' <<<"$response" 2>/dev/null)
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    system.log.error "FortiCare sign in did not return an access token"
    return 1
  fi

  local lifetime
  lifetime=$($JQ -rc '.expires_in // 3600' <<<"$response" 2>/dev/null)
  system.number "$lifetime" || lifetime=3600
  system.state.set forticare.deadline "$((SECONDS + lifetime))"

  {
    system.request.header "Content-Type: application/json"
    system.request.header "Authorization: Bearer $token"
  } >"$FORTICARE_CONFIG"

  system.log.info "FortiCare sign in done, token valid for ${lifetime}s"

  return 0
}

# Renews the token when it is about to expire.
fortimanager.token() {
  local deadline
  deadline=$(system.state.get forticare.deadline) || deadline=0
  system.number "$deadline" || deadline=0
  [ $((deadline - SECONDS)) -gt "$FORTICARE_RENEW_MARGIN" ] && return 0

  system.log.debug "FortiCare token about to expire, asking for a new one"
  fortimanager.login
}

# fortimanager.product.update <device JSON>
#
# Writes the description of one asset. Returns:
#   0 written (or nothing to do in rehearsal mode)
#   2 skipped on purpose (noasset tag, or no serial number)
#   1 failed
fortimanager.product.update() {
  local device="$1"

  local tag serial
  tag=$($JQ -rc '.tag' <<<"$device")
  serial=$($JQ -rc '.serial // "" | tostring' <<<"$device")

  if system.tag.contains "$tag" noasset; then
    return 2
  fi
  if [ -z "$serial" ] || [ "$serial" = "null" ]; then
    return 2
  fi

  local description
  description=$($JQ -rc '"[" + ( .name // "" ) + "] - " + ( .organization // "" )' <<<"$device")

  if [ "$SYSTEM_DRYRUN" -eq 1 ]; then
    system.rehearsal "FortiCare $serial would get the description $description"
    return 0
  fi

  fortimanager.token || return 1

  local body file
  body=$($JQ -nc --arg serial "$serial" --arg description "$description" \
    '{ "serialNumber": $serial, "description": $description }') || return 1
  file=$(system.request.body "$body") || return 1

  system.throttle forticare "$FORTICARE_RATE"

  local response
  if ! response=$(system.request POST "$FORTICARE_ENDPOINT/ES/api/registration/v3/products/description" \
    "$file" "$FORTICARE_CONFIG"); then
    system.log.debug "FortiCare answer for $serial: $(head -c 300 <<<"$response" | tr -d '\n')"
    return 1
  fi

  local status
  status=$($JQ -rc '.status // 1' <<<"$response" 2>/dev/null)
  system.number "${status#-}" || status=1
  if [ "$status" -ne 0 ]; then
    local message
    message=$($JQ -rc '.message // empty' <<<"$response" 2>/dev/null)
    system.log.debug "FortiCare refused serial number $serial${message:+: $message}"
    return 1
  fi

  return 0
}
