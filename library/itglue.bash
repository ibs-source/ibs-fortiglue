#!/bin/bash

# Include system.bash library
. /library/system.bash

# Check if RESPONSE variable is not defined
if ! [ -v RESPONSE ] ; then
  declare -a RESPONSE=()
fi

# Check if ENVIRONMENT_ITGLUE variable is not defined
if ! [ -v ENVIRONMENT_ITGLUE ] ; then
  RESPONSE+=("environment: Specifies the URL IT Glue API.")
fi

# Check if ENVIRONMENT_ITGLUE_APIKEY variable is not defined
if ! [ -v ENVIRONMENT_ITGLUE_APIKEY ] ; then
  RESPONSE+=("environment: Specifies the IT Glue API KEY.")
fi

ENVIRONMENT_ITGLUE_APIKEY="x-api-key: $ENVIRONMENT_ITGLUE_APIKEY"
ENVIRONMENT_ITGLUE_PAGINATION='{ data: [ .data[] | %s ], next: ( try( .meta["next-page"] ) // 0 ) }'

itglue.get.all()
{
  # Initialize variables
  local page=1
  local response='[]'
  local cmd=null

  # Loop until page is 0
  while [[ $page -ne 0 ]] ; do
    # Call the provided command with the current page and additional arguments
    cmd=$("${@:1:1}" $page "${@:2}")

    # Get the next page value from the command result
    page=$(echo "$cmd" | $JQ -rc '.next')

    # Append the data from the command result to the response
    response=$(echo "$cmd" | $JQ -rc --argjson old "$response" '$old + .data')
  done

  # Output the final response
  echo $response

  return 0
}

itglue.configuration.get()
{
  # Define the query string template
  local query='[ { "key": "page[size]", "value": 600 }, { "key": "page[number]", "value": %u }, { "key": "filter[archived]", "value": false }, { "key": "filter[configuration_status_id]", "value": %s } ]'

  # Format the query string with provided arguments
  local query=$(printf "$query" "$1" "$ENVIRONMENT_ITGLUE_CONFIGURATION_STATUS_ACTIVE")

  # Append additional arguments to the query string if provided
  [[ ! -z "$2" ]] && query=$($JQ -rc --argjson arguments "$2" '. + $arguments' <<< "$query")

  # Construct the final query string
  local query=$(system.querystring "$query")

  # Format and prepare the result extraction template
  local result='{ "id": .id|tonumber, "serial": .attributes["serial-number"], "name": .attributes.name, "organization": .attributes["organization-name"], "ip": .attributes["primary-ip"], "tag": tag(.attributes["asset-tag"]), "type": .attributes["configuration-type-name"], "manufacturer": .attributes["manufacturer-name"], "oid": .attributes["organization-id"]|tonumber, "short": .attributes["organization-short-name"] }'
  local result_extract=$(printf "$ENVIRONMENT_ITGLUE_PAGINATION" "$result")
  local result_extract_definition='def tag(x): x | if type == "string" then split( "," ) | map( gsub( "^\\s+|\\s+$"; "" ) ) else . end;'

  # Send the API request and extract the desired information using jq
  local result=$($CURL -s -G -H "Content-Type: application/vnd.api+json" -H "$ENVIRONMENT_ITGLUE_APIKEY" --compressed "https://$ENVIRONMENT_ITGLUE/configurations?$query")

  $JQ -rc "$result_extract_definition $result_extract" <<< "$result"

  return 0
}

itglue.organization.patch.shortname()
{
  # Define the query for updating the organization's short name and quick notes
  local query='{ "data": { "type": "organizations", "attributes": { "short_name": "%s", "quick-notes": "NAMING: %s" } } }'
  local query=$(printf "$query" "$2" "$2")

  # Perform the PATCH request to update the organization's information
  local result=$($CURL -s -X PATCH -H "Content-Type: application/vnd.api+json" -H "$ENVIRONMENT_ITGLUE_APIKEY" --compressed "https://$ENVIRONMENT_ITGLUE/organizations/$1" --data "$query")

  echo $result

  return 0
}

itglue.organization.get()
{
  # Define the query for retrieving organizations from IT Glue
  local query='[ { "key": "page[size]", "value": 600 }, { "key": "page[number]", "value": %u }, { "key": "filter[archived]", "value": false } ]'
  local query=$(printf "$query" "$1")

  # Add additional query parameters if provided
  [[ ! -z "$2" ]] && query=$($JQ -rc --argjson arguments "$2" '. + $arguments' <<< "$query")

  # Construct the final query string
  local query=$(system.querystring "$query")

  # Define the result extraction format
  local result='{ "oid": .id|tonumber, "name": .attributes.name, "short": .attributes["short-name"], "parent": .attributes["parent-id"] }'
  local result_extract=$(printf "$ENVIRONMENT_ITGLUE_PAGINATION" "$result")

  # Perform the GET request to retrieve organizations from IT Glue
  local result=$($CURL -s -G -H "Content-Type: application/vnd.api+json" -H "$ENVIRONMENT_ITGLUE_APIKEY" --compressed "https://$ENVIRONMENT_ITGLUE/organizations?$query")

  # Extract and format the desired result fields
  $JQ -rc "$result_extract" <<< "$result"

  return 0
}

itglue.flexible.get()
{
  # Define the query for flexible assets
  local query='[ { "key": "page[size]", "value": 600 }, { "key": "page[number]", "value": %u }, { "key": "filter[flexible-asset-type-id]", "value": %s } ]'
  local query=$(printf "$query" ${@:1:2})

  # Append additional arguments to the query if provided
  [[ ! -z "$3" ]] && query=$($JQ -rc --argjson arguments "$3" '. + $arguments' <<< "$query")

  # Convert the query to a query string format
  local query=$(system.querystring "$query")

  # Define the result extraction template
  local result='{ "id": .id|tonumber, "name": .attributes.name, "traits": .attributes.traits, "oid": .attributes["organization-id"]|tonumber }'
  local result_extract=$(printf "$ENVIRONMENT_ITGLUE_PAGINATION" "$result")

  # Send the request to retrieve flexible assets
  local result=$($CURL -s -G -H "Content-Type: application/vnd.api+json" -H "$ENVIRONMENT_ITGLUE_APIKEY" --compressed "https://$ENVIRONMENT_ITGLUE/flexible_assets?$query")

  # Extract the desired result fields from the response
  $JQ -rc "$result_extract" <<< "$result"

  return 0
}

itglue.contact.get()
{
  # Define the query for contacts
  local query='[ { "key": "page[size]", "value": 600 }, { "key": "page[number]", "value": %u } ]'
  local query=$(printf "$query" "$1")

  # Append additional arguments to the query if provided
  [[ ! -z "$2" ]] && query=$($JQ -rc --argjson arguments "$2" '. + $arguments' <<< "$query")

  # Convert the query to a query string format
  local query=$(system.querystring "$query")

  # Define the result extraction template
  local result='{ "id": .id|tonumber, "firstname": .attributes["first-name"], "lastname": .attributes["last-name"], "email": .attributes["contact-emails"], "oid": .attributes["organization-id"]|tonumber }'
  local result_extract=$(printf "$ENVIRONMENT_ITGLUE_PAGINATION" "$result")

  # Send the request to retrieve contacts
  local result=$($CURL -s -G -H "Content-Type: application/vnd.api+json" -H "$ENVIRONMENT_ITGLUE_APIKEY" --compressed "https://$ENVIRONMENT_ITGLUE/contacts?$query")

  # Extract the desired result fields from the response
  $JQ -rc "$result_extract" <<< "$result"

  return 0
}
