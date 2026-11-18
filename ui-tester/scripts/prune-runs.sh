#!/bin/bash
# SessionStart (startup|resume) hook in the ui-tester plugin's hooks/hooks.json, Tester sessions only.
# 1. Moves run folders an earlier version kept in ~/.claude/tester/runs/ into the
#    cache folder (lib-paths.sh), once.
# 2. Deletes each entry there in which nothing has changed for 7 days, so run
#    folders (screenshots, log streams) don't pile up forever. Age is the newest
#    modification time anywhere inside an entry, not its name or the folder's
#    own time, so a run folder a recheck wrote into stays its full 7 days from
#    that write.
[ "$TESTER_SESSION" = 1 ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
. "$SCRIPT_DIR/lib-paths.sh"

days=7
runs="$(tester_runs_dir)"
old="$HOME/.claude/tester/runs"

# A symlinked runs/ points somewhere this hook didn't make; leave it alone.
[ -L "$runs" ] && exit 0

if [ -d "$old" ] && [ ! -L "$old" ]; then
  moved=0
  if mkdir -p "$runs"; then
    while IFS= read -r -d '' entry; do
      dest="$runs/${entry##*/}"
      # Never overwrite a run already in the cache folder; the old copy stays.
      [ -e "$dest" ] || [ -L "$dest" ] || { mv -- "$entry" "$dest" && moved=$((moved + 1)); }
    done < <(find "$old" -mindepth 1 -maxdepth 1 -print0)
    rmdir "$old" 2>/dev/null
  fi
  [ "$moved" -eq 0 ] || echo "Moved $moved Tester run folder(s) from $old to $runs."
fi

[ -d "$runs" ] || exit 0

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
