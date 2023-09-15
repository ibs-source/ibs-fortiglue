#!/bin/bash

# Include system.bash library
. /library/system.bash

# Initialize RESPONSE array if not already defined
if ! [ -v RESPONSE ]; then
  declare -a RESPONSE=()
fi

# Check if ENVIRONMENT_FORTINET_USERNAME is not defined
if ! [ -v ENVIRONMENT_FORTINET_USERNAME ]; then
  RESPONSE+=("environment: Specifies the Fortinet username.")
fi

# Check if ENVIRONMENT_FORTINET_PASSWORD is not defined
if ! [ -v ENVIRONMENT_FORTINET_PASSWORD ]; then
  RESPONSE+=("environment: Specifies the Fortinet password.")
fi

# Check if ENVIRONMENT_FORTINET_CLIENTID is not defined
if ! [ -v ENVIRONMENT_FORTINET_CLIENTID ]; then
  RESPONSE+=("environment: Specifies the Fortinet clientid.")
fi

fortimanager.login() {
  # Define the query to obtain an access token
  local query='{ "username": "%s", "password": "%s", "client_id": "%s", "grant_type": "password" }'
  local query=$(printf "$query" "$ENVIRONMENT_FORTINET_USERNAME" "$ENVIRONMENT_FORTINET_PASSWORD" "$ENVIRONMENT_FORTINET_CLIENTID")

  # Send the query to obtain the access token
  local token=$($CURL -s -X POST -H "Content-Type: application/json" --compressed "https://customerapiauth.fortinet.com/api/v1/oauth/token/" --data "$query")

  # Extract the access token from the response
  local token=$($JQ -rc '.access_token' <<<"$token")

  # Check if the access token is empty
  if [ -z "$token" ]; then
    printf "\n\n\tSorry, this request could not be processed. Please try again later.\n\n"
    exit 1
  fi

  # Print the authorization header with the access token
  echo "Authorization: Bearer $token"

  return 0
}

fortimanager.product.list() {
  # Define the query to list products
  local query='{ "expireBefore":"2100-12-31T23:59:59" }'
  local query_extract='[ .assets[] | { "serial": .serialNumber, "description": .description } ]'

  # Send the query to list products and store the result
  local result=$($CURL -s -X POST -H "Content-Type: application/json" -H "$1" --compressed "https://support.fortinet.com/ES/api/registration/v3/products/list" --data "$query")

  # Extract and display the relevant information from the result
  $JQ -rc '[ .assets[] | { "serial": .serialNumber, "description": .description } ]' <<<"$result"

  return 0
}

fortimanager.product.update() {
  # Extract the 'tag' from the second argument using 'jq'
  local tag=$(echo "$2" | $JQ -rc '.tag')

  # Check if 'tag' contains the substring 'noasset'
  if [[ 0 -le $(system.indexof "$tag" "noasset") ]]; then
    # If 'tag' contains 'noasset', return success (0)
    return 0
  fi

  # Convert the second argument to a JSON object with specific fields and values
  local query=$(echo "$2" | $JQ -rc '{ "serialNumber": .serial, "description": ( "[" + .name + "] - " + .organization ) }')

  # Send a POST request to update the product information using the query data
  local status=$($CURL -s -X POST -H "Content-Type: application/json" -H "$1" --compressed "https://support.fortinet.com/ES/api/registration/v3/products/description" --data "$query")

  # Extract the 'status' field from the response using 'jq'
  local status=$($JQ -rc '.status' <<<"$status")

  # Check if the status is not equal to 0 (indicating an error)
  if [ $status -ne 0 ]; then
    # Extract the serial number and description from the query
    local serial=$(echo "$query" | $JQ -rc '.serialNumber')
    local description=$(echo "$query" | $JQ -rc '.description')

    # Print an error message indicating the invalid serial number and failed description update
    printf "\n\n\tInvalid Serial Number ($serial), failed to update description ($description).\n\n"

    # Return failure (1)
    return 1
  fi

  # Return success (0)
  return 0
}
