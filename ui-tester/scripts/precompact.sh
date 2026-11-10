#!/bin/bash
# PreCompact (auto) hook in the ui-tester plugin's hooks/hooks.json; acts only in sessions started from the saved Tester environment (TESTER_SESSION=1).
# Blocks automatic compaction while a run is in progress (~/.claude/tester/current.md
# exists), until the context reaches the user's global auto-compact window.
# Blocking at the API's hard limit fails the request instead of compacting
# (code.claude.com/docs/en/hooks.md, PreCompact), so every path that cannot
# measure allows compaction.
[ "$TESTER_SESSION" = 1 ] || exit 0

current="$HOME/.claude/tester/current.md"
[ -f "$current" ] || exit 0

transcript=$(jq -r '.transcript_path // empty')
[ -f "$transcript" ] || exit 0

last=$(tail -n 2000 "$transcript" \
  | jq -c 'select(.type == "assistant" and (.isSidechain | not) and .message.usage)' 2>/dev/null \
  | tail -n 1)
[ -n "$last" ] || exit 0

model=$(jq -r '.message.model // ""' <<<"$last" | sed 's/\[.*//')
used=$(jq '.message.usage | (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
  + (.cache_read_input_tokens // 0) + (.output_tokens // 0)' <<<"$last")

# Same precedence Claude Code uses within the user settings file: the model's
# modelSettings entry, then the top-level key; "auto" or unset is the default.
ceiling=$(jq -r --arg m "$model" '
  (.modelSettings[$m].autoCompactWindow) as $w
  | if $w == "auto" then empty
    elif ($w | type) == "number" then $w
    else (.autoCompactWindow | select(type == "number")) end' \
  "$HOME/.claude/settings.json" 2>/dev/null)
[[ "$ceiling" =~ ^[0-9]+$ ]] || ceiling=967000

[[ "$used" =~ ^[0-9]+$ ]] || exit 0
[ "$used" -lt "$ceiling" ] || exit 0

printf '{"decision":"block","reason":"Tester run in progress (%s of %s tokens); compaction waits for it to finish."}\n' "$used" "$ceiling"
