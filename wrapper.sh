#!/bin/bash

# Sourcing required libraries

. /library/system.bash
. /library/fortinet/analyzer.bash
. /library/fortinet/manager.bash
. /library/itglue.bash

# Naive check runs checks once a minute to see if either of the processes exited.
# This illustrates part of the heavy lifting you need to do if you want to run
# more than one service in a container. The container exits with job finish


HEALTH="/tmp/healthz"

# Function to stop the container
runner() {
  echo "Stop this container."
  exit 1
}

# Checking if the RESPONSE array is not defined and creating it if necessary
if ! [ -v RESPONSE ] ; then
  declare -a RESPONSE=()
fi

# Checking if the environment variable ENVIRONMENT_FORTIANALYZER_FOLDER is not defined and adding a message to RESPONSE if it's missing
if ! [ -v ENVIRONMENT_FORTIANALYZER_FOLDER ] ; then
  RESPONSE+=("environment: Specifies the Fortianalyzer destination folder.")
fi

# Checking if the environment variable ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID is not defined and adding a message to RESPONSE if it's missing
if ! [ -v ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID ] ; then
  RESPONSE+=("environment: Specifies the ITGlue ID of flexible asset type.")
fi

# Checking if RESPONSE array is not empty, printing the messages, and calling the runner function to stop the container
if [ ${#RESPONSE[@]} -ne 0 ] ; then
  printf '%s\n' "${RESPONSE[@]}"
  runner
fi

# Unsetting RESPONSE array
unset RESPONSE

# Setting the status to "ok" in the health file
echo "Status ok!" > "$HEALTH"

# Trap signals to call the runner function on SIGINT, SIGQUIT, SIGTERM
trap runner SIGINT SIGQUIT SIGTERM

# Displaying the content of instruction.txt file
cat /library/instruction.txt

# Logging in to Fortianalyzer and FortiManager, storing the session and authorization tokens
session=$(fortianalyzer.login)
authorization=$(fortimanager.login)

# Synchronization function
sync()
{
  local page=1 configuration=null name=null
  while [[ $page -ne 0 ]] ; do
    # Retrieve the configuration data from IT Glue based on the given page
    configuration=$(itglue.configuration.get "$page")

    # Extract the value of the 'next' field from the configuration data using JQ
    # and assign it to the 'page' variable for further processing
    page=$($JQ -rc '.next // 0' <<< "$configuration")

    # Iterating over the Fortinet items and updating them in FortiManager and FortiAnalyzer
    echo "$configuration" | $JQ -rc '.data[] | select( .manufacturer == "Fortinet" )' | while read configuration; do
      name=$($JQ -rc '"[" + .name + "] - " + .organization' <<< "$configuration")
  
      # Updating the item in FortiManager
      fortimanager.product.update "$1" "$configuration" &
      system.spinner "$name @ FortiManager"

      # Renaming the item in FortiAnalyzer
      fortianalyzer.device.rename "$2" "$configuration" &
      system.spinner "$name @ FortiAnalyzer"
    done
  done
}

# Report generation function
make()
{
  # Get organization
  local query='[ { "key": "filter[id]", "value": %s } ]'
  local query=$(printf "$query" $4)
  local query_response=$(itglue.get.all itglue.organization.get "$query" | $JQ -rc '.[0]')

  # Add previous Firewall on report recursive
  local passed="$5"
  [[ "array" != $($JQ -r 'type' <<< "$5") ]] && passed="[]"
  local passed=$($JQ -rc --argjson passed "$passed" --arg oid "$4" '$passed + [ .[] | select( .oid == ( $oid|tonumber ) ) | .name ]' <<< "$3")

  # Generate a ITGlue flexible filter to obtain a ITGlue ID recipients
  local query='[ { "key": "filter[organization-id]", "value": %s } ]'
  local query=$(printf "$query" "$4")
  local query_extract='try( [ .[].traits | { "language": ( .language|ascii_downcase ), contacts: [ .contacts.values[].id ] } ] | group_by( .language ) | map(first)[] ) // []'

  # Declare local variable for iterations
  local folder=null
  local object=null
  local profile=null 
  local language=null
  local contacts=null 
  local contacts_query=null

  # Store the shortname of organization
  local query_response_short=$($JQ -rc '.short' <<< "$query_response")

  itglue.get.all itglue.flexible.get "$ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID" "$query" | $JQ -rc "$query_extract" | while read object; do
    [ 0 -eq $($JQ 'try([ .contacts | unique ] | length) // 0' <<< "$object") ] && continue

    # Get language report
    language=$($JQ -rc '.language' <<< "$object")

    # Get contacts e-mail from ITGLue contact from ITGlue recipients id
    contacts=$($JQ -rc '[ { "key": "filter[id]", "value": ( .contacts | unique | join( "," ) ) } ]' <<< "$object")
    contacts_query='[ .[].email[] | select( .primary == true ) | .value ]'
    contacts=$(itglue.get.all itglue.contact.get "$contacts" | $JQ -rc "$contacts_query")

    [ 0 -eq $($JQ 'length' <<< "$contacts") ] && continue

    contacts_query='[ { "email-from": $from, "email-server": $smtp, "address": .[] } ]'
  
    # Search for the folder ID based on folder name
    folder=$(fortianalyzer.folder.search "${@:1:2}" "$query_response_short")

    # If the folder ID is less than 0, create folder
    [ $folder -lt 0 ] && folder=$(fortianalyzer.folder.create "${@:1:2}" "$ENVIRONMENT_FORTIANALYZER_FOLDER" "$query_response_short")

    # Generate e profile contacts
    contacts=$($JQ -rc --arg from "$ENVIRONMENT_FORTIANALYZER_EMAIL_FROM" --arg smtp "$ENVIRONMENT_FORTIANALYZER_EMAIL_SMTP" "$contacts_query" <<< "$contacts")
    
    profile=$(fortianalyzer.output.create "${@:1:2}" "$query_response_short" "$language" "$contacts")
    local file=null
    while read file; do
        file=$(basename $file .json)
        [[ "$file" == "email" ]] && continue

        # Create profile recipient e-mail
        file=$(fortianalyzer.layout.create "${@:1:2}" "$query_response_short" "$language" "$folder" "$file")

        # Create schedule
        fortianalyzer.schedule.create "${@:1:2}" "$file" "$profile" "$passed" >> /dev/null
    done <<< $(find "$TEMPLATE/${language}/" -type f)

  done

  local query_response_parent=$($JQ -rc '.parent // 0' <<< "$query_response")
  if [ $query_response_parent -gt 0 ] ; then
    report "${@:1:3}" "$query_response_parent" "$passed"
  fi  

  return 0
}

# Report generation function
report()
{
  local adom=null folders=null output=null devices=null oid=null
  # Listing ADOMs and performing report generation for each ADOM
  fortianalyzer.adom.list "$1" | $JQ -rc '.[].name' | while read adom; do
    printf "\n\n\tSearch $ENVIRONMENT_FORTIANALYZER_FOLDER in ADOM $adom."
    [ 0 -gt $(fortianalyzer.folder.search "$1" "$adom" "$ENVIRONMENT_FORTIANALYZER_FOLDER") ] && continue

    # Clean report folder
    folders=$(fortianalyzer.folder.sub "$1" "$adom" "$ENVIRONMENT_FORTIANALYZER_FOLDER")
    fortianalyzer.folder.delete "$1" "$adom" "$folders" &
    system.spinner "ADOM $adom clean report folder $ENVIRONMENT_FORTIANALYZER_FOLDER"

    # Clean output
    output=$(fortianalyzer.output.get "$1" "$adom")
    fortianalyzer.output.delete "$1" "$adom" "$output" &
    system.spinner "ADOM $adom clean output $ENVIRONMENT_FORTIANALYZER_FOLDER"

    # Listing Devices and performing report generation for organization
    devices=$(fortianalyzer.adom.devices "$1" "$adom" | $JQ -rc '[{"key":"filter[name]","value":( [ .[].name | select( test("[A-Z0-9]{4}-[A-Z0-9]{2}-FW[0-9]{2}") ) ] | join(",") )}]')

    if [ 0 -ne $($JQ -rc '.[0].value|length' <<< "$devices") ] ; then
      devices=$(itglue.get.all itglue.configuration.get "$devices" | $JQ -rc '[ .[] | { "name": .name, "oid": .oid } ] | unique')
      echo "$devices" | $JQ -rc '.[].oid' | while read oid; do
        make "$1" "$adom" "$devices" "$oid" &
        system.spinner "Check organization ($oid) report required in $adom"
      done
    fi

  done

  return 0
}

# Print a message indicating the start of naming synchronization between ITGlue and Fortinet application
printf "\n\n\tStart naming synchronization between ITGlue and Fortinet application!\n\n"

# Call the 'sync' function with the provided 'authorization' and 'session' parameters
sync "$authorization" "$session"

# Print a message indicating the start of automation to generate a report in FortiAnalyzer
printf "\n\n\tStart automation to generate report in FortiAnalyzer.\n\n"

# Call the 'report' function with the provided 'session' parameter
report "$session"

# Print a message indicating the completion of the process
printf "\n\n\tFinish!\n\n"

# Call the 'runner' function (assuming it exists)
runner

exit 0
