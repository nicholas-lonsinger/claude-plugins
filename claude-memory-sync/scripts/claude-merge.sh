#!/bin/bash
# git merge driver: semantic three-way merge via headless Claude.
# Registered as merge.claude-ai.driver by claude-sync.sh (re-stamped each
# run, since this script's plugin-cache path moves on every version bump);
# selected per-path in the state repo's .gitattributes.
#
# Args (from git): %O ancestor, %A ours (result must be written here), %B theirs, %P path
# Exit 0 = merged cleanly; non-zero = conflict (git records the path as conflicted).
set -u

BASE="$1"; OURS="$2"; THEIRS="$3"; PATHNAME="${4:-unknown}"
DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claude-memory-sync-nicholas-lonsinger-plugins}"
mkdir -p "$DATA"
LOG="$DATA/sync.log"

log() { printf '%s [merge] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG"; }

# Keep the headless session's hooks from re-entering the sync machinery,
# even when this driver is invoked by a manual `git merge`.
export CLAUDE_SYNC_ACTIVE=1

fallback() {
  # Standard three-way text merge; exit status reflects conflicts, which the
  # calling sync script treats as "abort and defer".
  git merge-file -L ours -L base -L theirs "$OURS" "$BASE" "$THEIRS"
  exit $?
}

command -v claude >/dev/null 2>&1 || { log "claude CLI not found; git merge-file fallback for $PATHNAME"; fallback; }

prompt=$(cat <<EOF
You are a git merge driver performing a semantic three-way merge of "$PATHNAME" from a Claude Code memory repo (persistent per-project memory markdown).

Rules:
- This is a union-of-knowledge merge: preserve every distinct fact, setting, and list item present on either side. Never pick one side wholesale.
- Use BASE to tell edits from additions: content present in BASE but removed by one side was deleted on purpose — keep it removed.
- If both sides edited the same item, merge the edits; if irreconcilable, keep the more complete version.
- Markdown memory files: keep frontmatter valid, merge list/bullet content, no duplicated entries.
- JSON files: output strictly valid JSON merging keys from both sides.
- Output ONLY the merged file content between <<<MERGED>>> and <<<END>>> markers, no commentary, no code fences.

=== BASE (common ancestor) ===
$(cat "$BASE")
=== OURS (this machine) ===
$(cat "$OURS")
=== THEIRS (other machine) ===
$(cat "$THEIRS")
EOF
)

# The model alias (not a pinned full name) always resolves to the latest
# Sonnet, so the driver doesn't silently age onto a deprecated model.
out=$(printf '%s' "$prompt" | claude -p --model sonnet 2>>"$LOG") || {
  log "claude -p failed for $PATHNAME; git merge-file fallback"
  fallback
}

merged=$(printf '%s\n' "$out" | awk '/^<<<MERGED>>>$/{f=1;next} /^<<<END>>>$/{f=0} f')
[ -z "$merged" ] && { log "no merged content extracted for $PATHNAME; git merge-file fallback"; fallback; }

# Plausibility guard: a union-of-knowledge merge can't come back smaller
# than half the SMALLER input side (even aggressive one-sided deletions
# leave the result near the side that kept less). A result below that
# indicates truncation or a hallucinated rewrite — the failure mode that
# silently loses memory — so hand it to the deterministic merge instead.
merged_len=$(($(printf '%s' "$merged" | wc -c)))
ours_len=$(($(wc -c <"$OURS" 2>/dev/null || echo 0)))
theirs_len=$(($(wc -c <"$THEIRS" 2>/dev/null || echo 0)))
min_len=$ours_len
[ "$theirs_len" -lt "$min_len" ] && min_len=$theirs_len
if [ "$merged_len" -lt $((min_len / 2)) ]; then
  log "merged output implausibly small ($merged_len of min-side $min_len bytes) for $PATHNAME; git merge-file fallback"
  fallback
fi

# A malformed JSON file would silently break whatever reads it — validate
# JSON before accepting the AI merge. (Memory scope is all-markdown today;
# this branch is defensive for any future whitelisted JSON.)
case "$PATHNAME" in
  *.json) printf '%s\n' "$merged" | jq -e . >/dev/null 2>&1 || { log "merged JSON invalid for $PATHNAME; git merge-file fallback"; fallback; } ;;
esac

printf '%s\n' "$merged" >"$OURS"
log "semantic merge OK for $PATHNAME"
exit 0
