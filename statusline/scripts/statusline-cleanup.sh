#!/bin/bash

# Read JSON session data from stdin
input=$(cat)

session_id=$(echo "$input" | jq -r '.session_id // ""')

if [ -n "$session_id" ]; then
    rm -f "/tmp/statusline-git-cache-${session_id}"
fi
