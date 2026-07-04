#!/bin/bash

# Read JSON session data from stdin
input=$(cat)

session_id=$(echo "$input" | jq -r '.session_id // ""')

# Wait for the final statusline refresh to complete, then clean up
# the session-specific cache file in the background
if [ -n "$session_id" ]; then
    (sleep 1 && rm -f "/tmp/statusline-git-cache-${session_id}") &
fi
