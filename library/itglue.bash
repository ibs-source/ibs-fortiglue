#!/bin/bash
#
# IT Glue REST client.
#
# Every call goes through system.request, so it gets a deadline, retries and a
# real check of the HTTP status: a failed page must never look like "no data".
# The API key travels in a curl configuration file, never in the arguments.

. /library/system.bash

ITGLUE_ENDPOINT=""
ITGLUE_CONFIG=""

# IT Glue allows 10 requests per second per key; staying slightly below keeps the
# nightly run away from 429 answers.
ITGLUE_RATE="${ENVIRONMENT_ITGLUE_RATE:-0.15}"

ITGLUE_PAGE_SIZE="${ENVIRONMENT_ITGLUE_PAGE_SIZE:-600}"

# Hard stop for pagination: without it a server answering always the same
# "next page" would keep the container busy until morning.
ITGLUE_PAGE_LIMIT="${ENVIRONMENT_ITGLUE_PAGE_LIMIT:-500}"

# Names asked for in a single filter[name]: an ADOM holding hundreds of
# firewalls would otherwise build a request line no server accepts.
ITGLUE_NAME_CHUNK="${ENVIRONMENT_ITGLUE_NAME_CHUNK:-50}"

# Environment variables owned by this module: name|requirement|description.
itglue.environment() {
  cat <<'VARIABLES'
ENVIRONMENT_ITGLUE|required|FQDN of the IT Glue API, for example api.eu.itglue.com
ENVIRONMENT_ITGLUE_APIKEY|required|API key of the IT Glue tenant
ENVIRONMENT_ITGLUE_CONFIGURATION_STATUS_ACTIVE|number|Identifier of the active configuration status
ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID|number|Identifier of the flexible asset type holding report recipients
ENVIRONMENT_ITGLUE_RATE|optional|Minimum seconds between two IT Glue calls, default 0.15
ENVIRONMENT_ITGLUE_PAGE_SIZE|count|Page size for IT Glue listings, default 600
ENVIRONMENT_ITGLUE_PAGE_LIMIT|count|Highest number of pages read from one listing, default 500
ENVIRONMENT_ITGLUE_NAME_CHUNK|count|Device names asked for in a single request, default 50
VARIABLES
}

# Prepares the endpoint and the curl configuration file holding the API key.
itglue.setup() {
  ITGLUE_ENDPOINT=$(system.endpoint "$ENVIRONMENT_ITGLUE")

  ITGLUE_CONFIG=$(system.temporary) || return 1
  {
    system.request.header "Content-Type: application/vnd.api+json"
    system.request.header "x-api-key: $ENVIRONMENT_ITGLUE_APIKEY"
  } >"$ITGLUE_CONFIG"

  system.log.debug "IT Glue endpoint $ITGLUE_ENDPOINT"

  return 0
}

# itglue.get <path> <query-json>
# Prints the JSON body of the answer. Fails when the call fails or the body is
# not valid JSON, so the caller can tell an error from an empty result.
itglue.get() {
  local path="$1"
  local query="$2"

  local string
  string=$(system.querystring "$query") || return 1

  local url="$ITGLUE_ENDPOINT/$path"
  [ -n "$string" ] && url="$url?$string"

  system.throttle itglue "$ITGLUE_RATE"

  local response
  if ! response=$(system.request GET "$url" "" "$ITGLUE_CONFIG"); then
    local detail
    detail=$($JQ -rc 'try( [ .errors[].title ] | join( "; " ) ) // empty' <<<"$response" 2>/dev/null)
    system.log.error "IT Glue GET /$path failed${detail:+: $detail}"
    return 1
  fi

  if ! system.json.valid "$response"; then
    system.log.error "IT Glue GET /$path returned a body that is not JSON"
    return 1
  fi

  echo "$response"

  return 0
}

# itglue.page <path> <query-json> <projection>
# Shapes one page as { "data": [ ... ], "next": <page number or 0> }.
itglue.page() {
  local path="$1"
  local query="$2"
  local projection="$3"

  local response
  response=$(itglue.get "$path" "$query") || return 1

  $JQ -rc "{ data: [ .data[]? | $projection ], next: ( .meta[\"next-page\"] // 0 | tonumber? // 0 ) }" <<<"$response"

  return 0
}

# itglue.get.all <page function> [arguments...]
# Walks every page and prints one JSON array with all the items. The page number
# must grow at each round, otherwise the loop stops with an error.
itglue.get.all() {
  local page=1
  local rounds=0

  # The pages pile up in a file, one item per line, and are gathered at the end:
  # a tenant with a few hundred configurations would not fit in an argument.
  local collected
  collected=$(system.temporary) || return 1
  : >"$collected"

  while [ "$page" -ne 0 ]; do
    local chunk
    chunk=$("$1" "$page" "${@:2}") || return 1

    local next
    next=$($JQ -rc '.next' <<<"$chunk")
    system.number "$next" || next=0

    $JQ -rc '.data[]?' <<<"$chunk" >>"$collected" || return 1

    rounds=$((rounds + 1))
    if [ "$next" -ne 0 ] && [ "$next" -le "$page" ]; then
      system.log.error "IT Glue pagination is not moving forward (page $page, next $next)"
      return 1
    fi
    if [ "$rounds" -ge "$ITGLUE_PAGE_LIMIT" ]; then
      system.log.error "IT Glue pagination exceeded $ITGLUE_PAGE_LIMIT pages, stopping"
      return 1
    fi

    page="$next"
  done

  $JQ -sc '.' "$collected"

  return 0
}

# --------------------------------------------------------------- endpoints

# itglue.configuration.get <page> [extra query JSON]
# Active, non archived configurations. The asset tag is normalised into a list.
itglue.configuration.get() {
  local query
  query=$($JQ -nc \
    --argjson size "$ITGLUE_PAGE_SIZE" \
    --argjson page "$1" \
    --arg status "$ENVIRONMENT_ITGLUE_CONFIGURATION_STATUS_ACTIVE" \
    --argjson extra "${2:-[]}" '
    [ { "key": "page[size]", "value": $size },
      { "key": "page[number]", "value": $page },
      { "key": "filter[archived]", "value": false },
      { "key": "filter[configuration_status_id]", "value": $status } ] + $extra
  ') || return 1

  local projection='{
    "id": ( .id | tonumber? // 0 ),
    "serial": .attributes["serial-number"],
    "name": .attributes.name,
    "organization": .attributes["organization-name"],
    "ip": .attributes["primary-ip"],
    "tag": ( .attributes["asset-tag"] | if type == "string" then split( "," ) | map( gsub( "^\\s+|\\s+$"; "" ) ) else . end ),
    "type": .attributes["configuration-type-name"],
    "manufacturer": .attributes["manufacturer-name"],
    "oid": ( .attributes["organization-id"] | tonumber? // 0 ),
    "short": .attributes["organization-short-name"]
  }'

  itglue.page configurations "$query" "$projection"
}

# itglue.organization.get <page> [extra query JSON]
itglue.organization.get() {
  local query
  query=$($JQ -nc \
    --argjson size "$ITGLUE_PAGE_SIZE" \
    --argjson page "$1" \
    --argjson extra "${2:-[]}" '
    [ { "key": "page[size]", "value": $size },
      { "key": "page[number]", "value": $page },
      { "key": "filter[archived]", "value": false } ] + $extra
  ') || return 1

  local projection='{
    "oid": ( .id | tonumber? // 0 ),
    "name": .attributes.name,
    "short": .attributes["short-name"],
    "parent": ( .attributes["parent-id"] | tonumber? // 0 )
  }'

  itglue.page organizations "$query" "$projection"
}

# itglue.flexible.get <page> <flexible asset type id> [extra query JSON]
itglue.flexible.get() {
  local query
  query=$($JQ -nc \
    --argjson size "$ITGLUE_PAGE_SIZE" \
    --argjson page "$1" \
    --arg type "$2" \
    --argjson extra "${3:-[]}" '
    [ { "key": "page[size]", "value": $size },
      { "key": "page[number]", "value": $page },
      { "key": "filter[flexible-asset-type-id]", "value": $type } ] + $extra
  ') || return 1

  local projection='{
    "id": ( .id | tonumber? // 0 ),
    "name": .attributes.name,
    "traits": .attributes.traits,
    "oid": ( .attributes["organization-id"] | tonumber? // 0 )
  }'

  itglue.page flexible_assets "$query" "$projection"
}

# itglue.contact.get <page> [extra query JSON]
itglue.contact.get() {
  local query
  query=$($JQ -nc \
    --argjson size "$ITGLUE_PAGE_SIZE" \
    --argjson page "$1" \
    --argjson extra "${2:-[]}" '
    [ { "key": "page[size]", "value": $size },
      { "key": "page[number]", "value": $page } ] + $extra
  ') || return 1

  local projection='{
    "id": ( .id | tonumber? // 0 ),
    "firstname": .attributes["first-name"],
    "lastname": .attributes["last-name"],
    "email": .attributes["contact-emails"],
    "oid": ( .attributes["organization-id"] | tonumber? // 0 )
  }'

  itglue.page contacts "$query" "$projection"
}

# itglue.contact.email <identifiers JSON array> <organization id>
#
# Primary e-mail addresses of the given contacts. An empty list of identifiers
# returns an empty list without calling IT Glue: an empty filter[id] would make
# the API answer with every contact of the tenant, and those addresses would end
# up receiving another customer's report.
itglue.contact.email() {
  local identifiers="$1"
  local oid="$2"

  local wanted
  wanted=$($JQ -rc '[ .[] | tonumber? // empty ] | unique' <<<"$identifiers" 2>/dev/null) || wanted='[]'

  if [ "$($JQ -r 'length' <<<"$wanted")" -eq 0 ]; then
    echo '[]'
    return 0
  fi

  local query
  query=$($JQ -nc --argjson wanted "$wanted" '
    [ { "key": "filter[id]", "value": ( $wanted | map( tostring ) | join( "," ) ) } ]
  ') || return 1

  local contacts
  contacts=$(itglue.get.all itglue.contact.get "$query") || return 1

  # Defence in depth: keep only the contacts that were actually asked for and
  # that belong to the organization being served.
  $JQ -rc --argjson wanted "$wanted" --argjson oid "$oid" '
    [ .[]
      | select( ( .id | IN( $wanted[] ) ) and ( $oid == 0 or .oid == $oid ) )
      | ( .email // [] )[]
      | select( .primary == true )
      | .value
      | select( type == "string" and ( . | test( "^[^@[:space:]]+@[^@[:space:]]+$" ) ) )
    ] | unique
  ' <<<"$contacts"

  return 0
}

# itglue.organization.by.id <organization id>
# The single organization, or an empty object when it does not exist.
itglue.organization.by.id() {
  local query
  query=$($JQ -nc --arg oid "$1" '[ { "key": "filter[id]", "value": $oid } ]') || return 1

  local response
  response=$(itglue.get.all itglue.organization.get "$query") || return 1

  $JQ -rc --argjson oid "$1" '[ .[] | select( .oid == $oid ) ] | first // {}' <<<"$response"

  return 0
}

# itglue.configuration.by.name <names JSON array>
# Active configurations matching the given names, asked for in blocks so the
# request line stays within what the API accepts.
itglue.configuration.by.name() {
  local names="$1"

  local total
  total=$($JQ -r 'length' <<<"$names")
  if [ "$total" -eq 0 ]; then
    echo '[]'
    return 0
  fi

  local response='[]'
  local offset=0
  local block query part
  while [ "$offset" -lt "$total" ]; do
    block=$($JQ -rc --argjson offset "$offset" --argjson size "$ITGLUE_NAME_CHUNK" \
      '.[ $offset : $offset + $size ]' <<<"$names") || return 1
    query=$($JQ -nc --argjson names "$block" \
      '[ { "key": "filter[name]", "value": ( $names | join( "," ) ) } ]') || return 1

    part=$(itglue.get.all itglue.configuration.get "$query") || return 1
    response=$($JQ -rc --argjson old "$response" '$old + .' <<<"$part") || return 1

    offset=$((offset + ITGLUE_NAME_CHUNK))
  done

  $JQ -rc 'unique_by( .id )' <<<"$response"

  return 0
}
