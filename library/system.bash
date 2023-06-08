#!/bin/bash

# Set the path to the 'jq' executable
JQ="/usr/bin/jq"

# Set the path to the 'curl' executable
CURL="/usr/bin/curl"

# Function for converting a query string to URI format
system.querystring()
{
  local query='def convert(x): x | @uri; [ .[] | convert( .key ) + "=" + convert( .value ) ] | join( "&" )'

  # Execute the JQ query to convert the query string to URI format
  $JQ -rc "$query" <<< "$1"

  return 0
}

# Function for finding the index of a substring in a string
system.indexof()
{
  local query='. | index( "%s" ) // -1'
  local query=$(printf "$query" "$2")

  # Execute the JQ query to find the index of the substring in the string
  $JQ -rc "$query" <<< "$1"

  return 0
}

# Function for displaying a spinner animation while a process is running
system.spinner()
{
    local pid=$!

    # Trap the EXIT signal to kill the spinner process
    trap "kill $pid 2> /dev/null" EXIT

    local time=0.01
    local string='|/-\'
    printf '\n\t%s:  ' "$1"

    # Keep displaying the spinner animation until the process is running
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${string#?}
        printf " [%c] " "$string"
        local string=$temp${string%"$temp"}
        sleep $time
        printf "\b\b\b\b\b"
    done

    printf "    \b\b\b\b\b"
    printf '[Ok]'

    # Reset the trap for the EXIT signal
    trap - EXIT

    return 0
}
