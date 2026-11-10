#!/bin/bash
# SessionStart (compact) hook in the ui-tester plugin's hooks/hooks.json, Tester sessions only: puts the
# Tester's on-disk state back in front of it after a compaction.
[ "$TESTER_SESSION" = 1 ] || exit 0
dir="$HOME/.claude/tester"
echo "This Tester session was just compacted. Work from the state on disk, not from the summary."
echo "Before the next run, re-read the project's testing docs (Setup step 3) that this compacted context does not already show in full."
echo
if [ -f "$dir/current.md" ]; then
  echo "A run is in progress: $dir/current.md"
else
  echo "No run is in progress."
fi
echo
echo "Queue, oldest first:"
for f in "$dir/queue"/*; do [ -e "$f" ] && echo "  $f"; done
[ -n "$(ls -A "$dir/queue" 2>/dev/null)" ] || echo "  (empty)"
echo
echo "== $dir/state.md =="
cat "$dir/state.md" 2>/dev/null || echo "(missing)"
