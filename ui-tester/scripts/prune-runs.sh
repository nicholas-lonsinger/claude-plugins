#!/bin/bash
# SessionStart (startup|resume) hook in the ui-tester plugin's hooks/hooks.json, Tester sessions only:
# deletes each entry under ~/.claude/tester/runs/ in which nothing has changed
# for 7 days, so run folders (screenshots, log streams) don't pile up forever.
# Age is the newest modification time anywhere inside an entry, not its name or
# the folder's own time, so a run folder a recheck wrote into stays its full 7
# days from that write.
[ "$TESTER_SESSION" = 1 ] || exit 0

days=7
runs="$HOME/.claude/tester/runs"
# A symlinked runs/ points somewhere this hook didn't make; leave it alone.
[ -d "$runs" ] && [ ! -L "$runs" ] || exit 0

# Minutes rather than -mtime: GNU find floors days and BSD find rounds them up,
# so the two would disagree by up to a day.
minutes=$((days * 24 * 60))
pruned=0
while IFS= read -r -d '' entry; do
  # Anything changed within the window keeps the whole entry.
  [ -z "$(find "$entry" -mmin "-$minutes" -print -quit 2>/dev/null)" ] || continue
  rm -rf -- "$entry" && pruned=$((pruned + 1))
done < <(find "$runs" -mindepth 1 -maxdepth 1 -print0)

[ "$pruned" -eq 0 ] || echo "Removed $pruned Tester run folder(s) under $runs with nothing changed in $days days."
exit 0
