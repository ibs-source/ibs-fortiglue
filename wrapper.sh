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
if ! [ -v RESPONSE ]; then
  declare -a RESPONSE=()
fi

# Checking if the environment variable ENVIRONMENT_FORTIANALYZER_FOLDER is not defined and adding a message to RESPONSE if it's missing
if ! [ -v ENVIRONMENT_FORTIANALYZER_FOLDER ]; then
  RESPONSE+=("environment: Specifies the Fortianalyzer destination folder.")
fi

# Checking if the environment variable ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID is not defined and adding a message to RESPONSE if it's missing
if ! [ -v ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID ]; then
  RESPONSE+=("environment: Specifies the ITGlue ID of flexible asset type.")
fi

# Checking if RESPONSE array is not empty, printing the messages, and calling the runner function to stop the container
if [ ${#RESPONSE[@]} -ne 0 ]; then
  printf '%s\n' "${RESPONSE[@]}"
  runner
fi

# Unsetting RESPONSE array
unset RESPONSE

# Setting the status to "ok" in the health file
echo "Status ok!" >"$HEALTH"

# Trap signals to call the runner function on SIGINT, SIGQUIT, SIGTERM
trap runner SIGINT SIGQUIT SIGTERM

# Displaying the content of instruction.txt file
cat /library/instruction.txt

# Logging in to Fortianalyzer and FortiManager, storing the session and authorization tokens
GSESSION=$(fortianalyzer.login)
GAUTHORIZATION=$(fortimanager.login)

# Responsible for updating the items in FortiManager and renaming the
# items in FortiAnalyzer.
syncupdate() {
  local devices="$1"
  local name=$($JQ -rc '"[" + .name + "] - " + .organization' <<<"$devices")

  # Updating the item in FortiManager
  fortimanager.product.update "$GAUTHORIZATION" "$devices" &
  system.spinner "$name @ FortiManager"

  # Renaming the item in FortiAnalyzer
  fortianalyzer.device.rename "$GSESSION" "$devices" &
  system.spinner "$name @ FortiAnalyzer"

  return 0
}

# Synchronization function
sync() {
  local page=1
  local devices=null
  while [[ $page -ne 0 ]]; do
    # Retrieve the configuration data from IT Glue based on the given page
    local configuration=$(itglue.configuration.get "$page")

    # Extract the value of the 'next' field from the configuration data using JQ
    # and assign it to the 'page' variable for further processing
    page=$($JQ -rc '.next // 0' <<<"$configuration")

    # Iterating over the Fortinet items and updating them in FortiManager and FortiAnalyzer
    echo "$configuration" | $JQ -rc '.data[] | select( .manufacturer == "Fortinet" )' | while read devices; do
      syncupdate "$devices"
    done
  done

  return 0
}

# Responsible for generating reports in FortiAnalyzer for a
# specific ADOM in the Fortinet application.
reportmymakeitem() {
  local adom="$1"
  local object="$2"
  local response_short="$3"
  local language=$($JQ -rc '.language' <<<"$object")

  # Get contacts e-mail from ITGLue contact from ITGlue recipients id
  local contacts=$($JQ -rc '[ { "key": "filter[id]", "value": ( .contacts | unique | join( "," ) ) } ]' <<<"$object")
  local contacts=$(itglue.get.all itglue.contact.get "$contacts" | $JQ -rc '[ .[].email[] | select( .primary == true ) | .value ]')
  [ 0 -eq $($JQ 'length' <<<"$contacts") ] && return 1

  # Search for the folder ID based on folder name
  local folder=$(fortianalyzer.folder.search "$GSESSION" "$adom" "$response_short")

  # If the folder ID is less than 0, create folder
  [ $folder -lt 0 ] && folder=$(fortianalyzer.folder.create "$GSESSION" "$adom" "$ENVIRONMENT_FORTIANALYZER_FOLDER" "$response_short")

  local file=null
  # Uncomment this line to force the email recipients. Used for developer purpose.
  # <code data-overload>
  #   local contacts='["alessandro.civiero@ibs.srl","paolo.moserle@ibs.srl","luca.attori@ibs.srl"]'
  # </code>
  local contacts=$($JQ -rc --arg from "$ENVIRONMENT_FORTIANALYZER_EMAIL_FROM" --arg smtp "$ENVIRONMENT_FORTIANALYZER_EMAIL_SMTP" '[ { "email-from": $from, "email-server": $smtp, "address": .[] } ]' <<<"$contacts")
  local profile=$(fortianalyzer.output.create "$GSESSION" "$adom" "$response_short" "$language" "$contacts")
  while read file; do
    local name=$(basename "$file" .json)
    [[ "email" == "$name" ]] && continue

    # Create profile recipient e-mail and schedule
    local file=$(fortianalyzer.layout.create "$GSESSION" "$adom" "$response_short" "$language" "$folder" "$name")
    fortianalyzer.schedule.create "$GSESSION" "$adom" "$file" "$profile" "$passed" >>/dev/null
  done <<<$(find "$TEMPLATE/${language}/" -type f)

  return 0
}

# Report generation function
reportmymake() {
  local oid="$3"
  local adom="$1"
  local configuration="$2"

  # Get organization
  local query='[ { "key": "filter[id]", "value": %s } ]'
  local query=$(printf "$query" "$oid")
  local query_response=$(itglue.get.all itglue.organization.get "$query" | $JQ -rc '.[0]')

  # Add previous Firewall on report recursive
  local passed="$4"
  [[ "array" != $($JQ -r 'type' <<<"$passed") ]] && passed="[]"
  local passed=$($JQ -rc --argjson passed "$passed" --arg oid "$oid" '$passed + [ .[] | select( .oid == ( $oid|tonumber ) ) | .name ]' <<<"$configuration")

  # Generate a ITGlue flexible filter to obtain a ITGlue ID recipients
  local query='[ { "key": "filter[organization-id]", "value": %s } ]'
  local query=$(printf "$query" "$oid")

  # Declare local variable for iterations
  local object=null

  # Store the shortname of organization
  local response_short=$($JQ -rc '.short' <<<"$query_response")

  local query_extract='try( [ .[].traits | { "language": ( .language|ascii_downcase ), contacts: [ .contacts.values[].id ] } ] | group_by( .language ) | map(first)[] ) // []'
  itglue.get.all itglue.flexible.get "$ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID" "$query" | $JQ -rc "$query_extract" | while read object; do
    [ 0 -eq $($JQ 'try([ .contacts | unique ] | length) // 0' <<<"$object") ] && continue
    reportmymakeitem "$adom" "$object" "$response_short"
  done

  local query_response_parent=$($JQ -rc '.parent // 0' <<<"$query_response")
  if [ $query_response_parent -gt 0 ]; then
    reportmymake "$adom" "$configuration" "$query_response_parent" "$passed"
  fi

  return 0
}

# Responsible for generating reports in FortiAnalyzer for a specific ADOM
# in the Fortinet application.
reportmy() {
  local adom="$1"

  printf "\n\n\tSearch $ENVIRONMENT_FORTIANALYZER_FOLDER in ADOM $adom."
  [ 0 -gt $(fortianalyzer.folder.search "$GSESSION" "$adom" "$ENVIRONMENT_FORTIANALYZER_FOLDER") ] && return 1

  # Clean report folder
  local folders=$(fortianalyzer.folder.sub "$GSESSION" "$adom" "$ENVIRONMENT_FORTIANALYZER_FOLDER")
  fortianalyzer.folder.delete "$GSESSION" "$adom" "$folders" &
  system.spinner "ADOM $adom clean report folder $ENVIRONMENT_FORTIANALYZER_FOLDER"

  # Clean output
  local output=$(fortianalyzer.output.get "$GSESSION" "$adom")
  fortianalyzer.output.delete "$GSESSION" "$adom" "$output" &
  system.spinner "ADOM $adom clean output $ENVIRONMENT_FORTIANALYZER_FOLDER"

  # Listing Devices and performing report generation for organization
  local devices=$(fortianalyzer.adom.devices "$GSESSION" "$adom" | $JQ -rc '[{"key":"filter[name]","value":( [ .[].name | select( test("[A-Z0-9]{4}-[A-Z0-9]{2}-FW[0-9]{2}") ) ] | join(",") )}]')

  if [ 0 -ne $($JQ -rc '.[0].value|length' <<<"$devices") ]; then
    local oid=null
    local configuration=$(itglue.get.all itglue.configuration.get "$devices" | $JQ -rc '[ .[] | { "name": .name, "oid": .oid } ] | unique')
    echo "$configuration" | $JQ -rc '[ .[].oid ] | unique | .[]' | while read oid; do
      reportmymake "$adom" "$configuration" "$oid" &
      system.spinner "Check organization ($oid) report required in $adom"
    done
  fi

  return 0
}

# Report generation function
report() {
  local adom=null
  # Listing ADOMs and performing report generation for each ADOM
  fortianalyzer.adom.list "$GSESSION" | $JQ -rc '.[].name' | while read adom; do
    reportmy "$adom"
  done

  return 0
}

# Checking if the environment variable ENVIRONMENT_FORTINET_NOSYNC is not defined for run sync process
if ! [ -v ENVIRONMENT_FORTINET_NOSYNC ]; then
  # Print a message indicating the start of naming synchronization between ITGlue and all Fortinet application
  printf "\n\n\tStart naming synchronization between ITGlue and Fortinet application!\n\n"

  sync
fi

# Print a message indicating the start of automation to generate a report in FortiAnalyzer
printf "\n\n\tStart automation to generate report in FortiAnalyzer.\n\n"

report

# Print a message indicating the completion of the process
printf "\n\n\tFinish!\n\n"

# Call the 'runner' function (assuming it exists)
runner

exit 0
