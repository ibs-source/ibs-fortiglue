#!/bin/bash

# Include system.bash library
. /library/system.bash

# Specify the template file path
TEMPLATE=/library/fortinet/template

# Initialize RESPONSE array if not already defined
if ! [ -v RESPONSE ]; then
  declare -a RESPONSE=()
fi

# Check if ENVIRONMENT_FORTIANALYZER_FQDN is not defined
if ! [ -v ENVIRONMENT_FORTIANALYZER_FQDN ]; then
  RESPONSE+=("environment: Specifies the Fortianalyzer FQDN.")
fi

# Check if ENVIRONMENT_FORTIANALYZER_USERNAME is not defined
if ! [ -v ENVIRONMENT_FORTIANALYZER_USERNAME ]; then
  RESPONSE+=("environment: Specifies the Fortianalyzer username.")
fi

# Check if ENVIRONMENT_FORTIANALYZER_PASSWORD is not defined
if ! [ -v ENVIRONMENT_FORTIANALYZER_PASSWORD ]; then
  RESPONSE+=("environment: Specifies the Fortianalyzer password.")
fi

fortianalyzer.repeat() {
  # Set the initial value of id to null
  local id=null

  # Set the value of iterate to the third argument passed to the function
  local iterate="$3"

  # Check if the type of the third argument is not an array using JQ
  # If it's not an array, set the value of iterate to an empty array
  [[ "array" != $($JQ -r 'type' <<<"$3") ]] && iterate="[]"

  # Iterate over the items in iterate and perform the specified query
  echo "$iterate" | $JQ -rc '.[]' | while read id; do
    # Generate the query by replacing placeholders in the fourth argument with the provided arguments
    local query=$(printf "$4" "${@:1:2}" "$id")

    # Execute the query using CURL and discard the output by redirecting it to /dev/null
    $CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query" >>/dev/null
  done

  # Return 0 to indicate success
  return 0
}

fortianalyzer.login() {
  # Create the login query using the provided username and password
  local query='{ "id":1, "method": "exec", "params": [ { "data": { "passwd": "%s",  "user": "%s"  },  "url":  "/sys/login/user" } ] }'
  local query=$(printf "$query" "$ENVIRONMENT_FORTIANALYZER_PASSWORD" "$ENVIRONMENT_FORTIANALYZER_USERNAME")

  # Execute the login query using CURL and store the result in query_result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Extract and output the session value from the query_result using JQ
  $JQ -rc '.session' <<<"$query_result"

  # Return 0 to indicate success
  return 0
}

fortianalyzer.adom.list() {
  # Create the query for listing ADOMs using the provided session value
  local query='{ "id": 1, "method": "get", "session": "%s", "params": [ { "url": "/dvmdb/adom" } ] }'
  local query=$(printf "$query" "${@:1:1}")

  # Execute the query using CURL and store the result in query_result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Extract the name property from each ADOM in the query_result using JQ
  $JQ -rc '[ .result[0].data[] | { "name": .name } ]' <<<"$query_result"

  # Return 0 to indicate success
  return 0
}

fortianalyzer.adom.devices() {
  # Define the query template with placeholders for session and ADOM name
  local query='{ "id": 1, "method": "get", "session": "%s", "params": [ { "url": "/dvmdb/adom/%s/device" } ] }'

  # Populate the query template with session and ADOM name
  local query=$(printf "$query" "${@:1:2}")

  # Send the query to the Fortianalyzer API and store the result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Extract the device names from the query result using JQ
  $JQ -rc '[ .result[0].data[] | { "name": .name } ]' <<<"$query_result"

  return 0
}

fortianalyzer.folder.search() {
  # Define the query template with placeholders for session, ADOM name, and folder name
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "get", "session": "%s", "params": [ { "apiver": 3, "url": "/report/adom/%s/config/layout-folder" } ] }'

  # Populate the query template with session and ADOM name
  local query=$(printf "$query" "${@:1:2}")

  # Send the query to the Fortianalyzer API and store the result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Define a query to extract the folder ID based on the folder name
  local query_result_extract='try( .result.data[] | select( .["folder-name"] == "%s" ) | .["folder-id"] ) // -1'

  # Populate the query to extract the folder ID with the folder name
  local query_result_extract=$(printf "$query_result_extract" "$3")

  # Extract the folder ID from the query result using JQ
  $JQ -rc "$query_result_extract" <<<"$query_result"

  return 0
}

fortianalyzer.folder.sub() {
  # Search for the folder ID based on session, ADOM name, and folder name
  local id=$(fortianalyzer.folder.search "${@:1:3}")

  # If the folder ID is less than 0, return an empty array
  if [ $id -lt 0 ]; then
    echo '[]' && return 0
  fi

  # Define the query template with placeholders for session, ADOM name, and folder ID
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "get", "session": "%s", "params": [ { "apiver": 3, "url": "/report/adom/%s/config/layout-folder", "filter": [ [ "parent-id", "==", "%u" ] ] } ] }'

  # Populate the query template with session, ADOM name, and folder ID
  local query=$(printf "$query" "${@:1:2}" "$id")

  # Send the query to the Fortianalyzer API and store the result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Extract the folder IDs from the query result using JQ
  $JQ -rc '[ .result.data[] | .["folder-id"] ]' <<<"$query_result"

  return 0
}

fortianalyzer.folder.delete() {
  # Define the query template with placeholders for session, ADOM name, and folder ID
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "delete", "session": "%s", "params": [ { "apiver": 3, "url": "/report/adom/%s/config/layout-folder/%u" } ] }'

  # Get the layout ID using fortianalyzer.layout.get function
  local layout=$(fortianalyzer.layout.get "${@:1:3}" | $JQ -rc '[ .[]["layout-id"] ]')

  # Delete the layout using fortianalyzer.layout.delete function
  fortianalyzer.layout.delete "${@:1:2}" "$layout"

  # Repeat the delete operation using the provided query template
  fortianalyzer.repeat "${@:1:3}" "$query"

  return 0
}

fortianalyzer.folder.create() {
  # Search for the folder ID based on session, ADOM name, and folder name
  local id=$(fortianalyzer.folder.search "${@:1:3}")

  # Define the query template with placeholders for session, ADOM name, folder name, and parent ID
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "add", "session": "%s", "params": [ { "apiver": 3, "url": "/report/adom/%s/config/layout-folder", "data": { "folder-name": "%s", "parent-id": %u } } ] }'

  # Populate the query template with session, ADOM name, folder name, and parent ID
  local query=$(printf "$query" "${@:1:2}" "$4" "$id")

  # Send the query to the Fortianalyzer API and store the result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Check if the folder was successfully created based on the status code in the query result
  if [ 0 -ne $($JQ -rc '.result.status.code // 0' <<<"$query_result") ]; then
    printf "\n\n\tThe folder ($4) not created.\n\n" && return 1
  fi

  # Extract the folder ID from the query result using JQ
  $JQ -rc '.result.data["folder-id"]' <<<"$query_result"

  return 0
}

fortianalyzer.device.search() {
  # Extract the serial number from the input using JQ
  local query_serial=$(echo "$2" | $JQ -rc '.serial')

  # Define the query template with placeholders for session and serial number
  local query='{ "id": 1, "method": "get", "session": "%s", "params": [ { "filter": [ [ "sn", "==", "%s" ] ], "url": "/dvmdb/device" } ] }'

  # Populate the query template with session and serial number
  local query=$(printf "$query" "$1" "$query_serial")

  # Send the query to the Fortianalyzer API and store the result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Extract the device name from the query result using JQ
  $JQ -rc '.result[0].data[0].name // 0' <<<"$query_result"

  return 0
}

fortianalyzer.device.rename() {
  local ip=$(echo "$2" | $JQ -rc '.ip')
  local tag=$(echo "$2" | $JQ -rc '.tag')
  local type=$(echo "$2" | $JQ -rc '.type')

  # Check if the device tag contains "nofaz", or if the type is not "Firewall",
  # or if the IP is null. If any of these conditions are true, return 0.
  if [[ 0 -le $(system.indexof "$tag" "nofaz") ]] || [ "$type" != "Firewall" ] || [ "$ip" == "null" ]; then
    return 0
  fi

  local name=$(echo "$2" | $JQ -rc '.name')
  local serial=$(echo "$2" | $JQ -rc '.serial')
  local previous=$(fortianalyzer.device.search "$1" "$2")
  local organization=$(echo "$2" | $JQ -rc '.organization')

  # If the previous device is not found, print an error message and return 1.
  if [ "$previous" == "0" ]; then
    printf "\n\n\tThe Serial Number ($serial) not found ($ENVIRONMENT_FORTIANALYZER_FQDN). Reference name ($name).\n\n" && return 1
  fi

  local query='{ "id": 1, "method": "set", "session": "%s", "params": [ { "data": { "name": "%s", "desc": "%s" }, "url": "/dvmdb/device/%s" } ] }'
  local query=$(printf "$query" "$1" "$name" "$organization" "$previous")
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # If the renaming fails, print an error message and return 1.
  if [ 0 -ne $($JQ -rc '.result[0].status.code // 0' <<<"$query_result") ]; then
    printf "\n\n\tThe Serial Number ($serial) not renamed ($name).\n\n" && return 1
  fi

  return 0
}

fortianalyzer.schedule.get() {
  # Construct the query to retrieve schedule information
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "get", "session": "%s", "params": [ { "apiver": 3, "url": "/report/adom/%s/config/schedule" } ] }'
  local query=$(printf "$query" "${@:1:2}")

  # Send the query and store the result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Extract specific data from the query result based on the provided condition
  local query_result_extract='[ .result.data[] | select( .name | tonumber | %s ) ]'
  local query_result_extract_play=$($JQ -rc '[ .[] | tostring | ". == " + . ] | if .|length != 0 then join( " or " ) else false end' <<<"$3")
  local query_result_extract=$(printf "$query_result_extract" "$query_result_extract_play")

  # Use JQ to extract the desired data from the query result
  $JQ -rc "$query_result_extract" <<<"$query_result"

  return 0
}

fortianalyzer.schedule.delete() {
  # Construct the query to delete a schedule
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "delete", "session": "%s", "params": [ { "apiver": 3, "url":"/report/adom/%s/config/schedule/%u" } ] }'

  # Use the fortianalyzer.repeat function to repeat the delete operation for multiple schedules
  fortianalyzer.repeat "${@:1:3}" "$query"

  return 0
}

fortianalyzer.schedule.create() {
  # Construct the query to create a schedule
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "add", "session": "%s", "params": [ { "apiver": 3, "url":"/report/adom/%s/config/schedule", "data": %s } ] }'
  local query_body='{ "name": "", "output-profile": "", "devices": [], "report-layout": [] }'
  local query=$(printf "$query" "${@:1:2}" "$query_body")

  # Build the query body using the provided arguments
  local query_build='.params[0].data = ( .params[0].data * $template ) | .params[0].data.name = $name | .params[0].data["output-profile"] = $profile | .params[0].data["report-layout"] = [ { "layout-id": ( $name|tonumber ) } ] | .params[0].data.devices = ( [ { "interfaces": null, "devices-name": $devices[] } ] ) '
  local query=$($JQ -rc --argfile template "$TEMPLATE/schedule.json" --arg name "$3" --arg profile "$4" --argjson devices "$5" "$query_build" <<<"$query")

  # Send the query to create the schedule and store the result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Check the status code in the query result and display an error message if it's not successful
  if [ 0 -ne $($JQ -rc '.result.status.code // 0' <<<"$query_result") ]; then
    printf "\n\n\tThe Schedule Profile ($4) not created for Report ($3).\n\n" && return 1
  fi

  # Extract the name of the created schedule from the query result
  $JQ -rc '.result.data.name' <<<"$query_result"

  return 0
}
fortianalyzer.layout.get() {
  # Construct the query to retrieve layout data
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "get", "session": "%s", "params": [ { "apiver": 3, "url": "/report/adom/%s/config/layout" } ] }'
  local query=$(printf "$query" "${@:1:2}")

  # Send the query and store the result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Extract the desired data from the query result
  local query_result_extract='[ .result.data[] | select( .folders[]["folder-id"] | %s ) ]'
  local query_result_extract_play=$($JQ -rc '[ .[] | tostring | ". == " + . ] | if .|length != 0 then join( " or " ) else false end' <<<"$3")
  local query_result_extract=$(printf "$query_result_extract" "$query_result_extract_play")

  # Extract and return the relevant data
  $JQ -rc "$query_result_extract" <<<"$query_result"

  return 0
}

fortianalyzer.layout.delete() {
  # Construct the query to delete a layout
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "delete", "session": "%s", "params": [ { "apiver": 3, "url": "/report/adom/%s/config/layout/%u" } ] }'

  # Retrieve the schedule for the layout
  local schedule=$(fortianalyzer.schedule.get "${@:1:3}" | $JQ -rc '[ .[].name ]')

  # Delete the schedule for the layout
  fortianalyzer.schedule.delete "${@:1:2}" "$schedule"

  # Delete the layout
  fortianalyzer.repeat "${@:1:3}" "$query"

  return 0
}

fortianalyzer.layout.create() {
  # Load the template query from the specified template file
  local template_query='.language = $language | .title = ( $short|ascii_upcase) + "-" + ( $language|ascii_upcase ) + "-" + .title | .folders[0]["folder-id"] = ( $id|tonumber )'
  local template=$($JQ -rc --arg id "$5" --arg short "$3" --arg language "$4" "$template_query" "$TEMPLATE/${4}/${6}.json")

  # Construct the query to create a layout
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "add", "session": "%s", "params": [ { "apiver": 3, "url": "/report/adom/%s/config/layout", "data": { } } ] }'
  local query=$(printf "$query" "${@:1:2}")

  # Set the template data in the query
  local query=$($JQ -rc --argjson template "$template" '.params[0].data = $template' <<<"$query")

  # Send the query to create the layout and store the result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Check if the layout creation was successful
  if [ 0 -ne $($JQ -rc '.result.status.code // 0' <<<"$query_result") ]; then
    printf "\n\n\tThe report ($4 - $6) not created in folder ($3).\n\n" && return 1
  fi

  # Extract and return the layout ID
  $JQ -rc '.result.data["layout-id"]' <<<"$query_result"

  return 0
}

fortianalyzer.output.get() {
  # Construct the query to get the output configuration
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "get", "session": "%s", "params": [ { "apiver": 3, "url": "/report/adom/%s/config/output" } ] }'
  local query=$(printf "$query" "${@:1:2}")

  # Send the query to Fortianalyzer and store the result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Extract the names of the outputs from the query result using JQ
  $JQ -rc '[ .result.data[].name ]' <<<"$query_result"

  return 0
}

fortianalyzer.output.delete() {
  # Construct the query to delete an output configuration
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "delete", "session": "%s", "params": [ { "apiver": 3, "url": "/report/adom/%s/config/output/%s" } ] }'

  # Repeat the query for each specified output ID using the fortianalyzer.repeat function
  fortianalyzer.repeat "${@:1:3}" "$query"

  return 0
}

fortianalyzer.output.create() {
  # Construct the query to create a new output configuration
  local query='{ "id": 1, "jsonrpc": "2.0", "method": "add", "session": "%s", "params": [ { "apiver": 3, "url": "/report/adom/%s/config/output", "data": %s } ] }'

  # Specify the default query body for creating an output
  local query_body='{ "email": 1, "email-attachment-compress": 0, "email-recipients": [], "name": "" }'

  # Format the query with the provided parameters
  local query=$(printf "$query" "${@:1:2}" "$query_body")

  # Build the final query by modifying the query body using JQ
  local query_build='.params[0].data = ( .params[0].data * $template ) | .params[0].data["email-recipients"] = $recipients | .params[0].data.name = ( ( $short|ascii_upcase) + "-" + ($language|ascii_upcase) )'

  # Use JQ to replace placeholders in the query with actual values
  local query=$($JQ -rc --arg language "$4" --arg short "$3" --argjson recipients "$5" --argfile template "$TEMPLATE/${4}/email.json" "$query_build" <<<"$query")

  # Send the query to Fortianalyzer and store the result
  local query_result=$($CURL -s -X POST -H "Content-Type: application/json" --compressed --insecure "https://$ENVIRONMENT_FORTIANALYZER_FQDN/jsonrpc" --data "$query")

  # Check if the creation of the output was successful
  if [ 0 -ne $($JQ -rc '.result.status.code // 0' <<<"$query_result") ]; then
    printf "\n\n\tThe output (${3}-${4}) not created.\n\n" && return 1
  fi

  # Extract the name of the created output from the query result using JQ
  $JQ -rc '.result.data.name' <<<"$query_result"

  return 0
}
