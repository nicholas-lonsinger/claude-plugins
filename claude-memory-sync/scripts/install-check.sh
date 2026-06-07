#!/bin/bash
# install-check.sh — SessionStart hook (synchronous).
#
# Verifies memory sync is set up on this machine and, if not, prints a
# one-line nudge. SessionStart stdout is added to Claude's session context,
# so the nudge is what prompts Claude to offer /claude-memory-sync:install —
# nothing is ever changed automatically.
#
# This check is deliberately separate from claude-sync.sh: the pull hook is
# async (its stdout can't reliably reach session context), so the sync
# script no-ops silently when not installed and this script owns the nudge.
# Matcher-less SessionStart hooks also run on resume/clear/compact, so the
# nudge re-asserts itself across compaction for as long as it stays true.
#
# Always exits 0 — a missing setup must never block a session.
set -u

DIR="$HOME/.claude"
DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claude-memory-sync-nicholas-lonsinger-plugins}"
MARKER="$DATA/state-repo"

# Headless merge session (claude -p inside the merge driver) — stay silent.
[ -n "${CLAUDE_SYNC_ACTIVE:-}" ] && exit 0

if [ ! -f "$MARKER" ]; then
  echo "claude-memory-sync: the plugin is installed and its sync hooks are active, but setup is not complete on this machine — completing it requires running /claude-memory-sync:install (interactive; it asks which private GitHub repo to sync memory to). At the start of the session, briefly explain this and ask the user whether to run it now. If they decline, drop the subject for the rest of the session."
  exit 0
fi

SLUG="$(cat "$MARKER" 2>/dev/null)"
if [ ! -d "$DIR/.git" ]; then
  echo "claude-memory-sync: this machine is configured to sync memory to '$SLUG', but ~/.claude is not a git repo — sync is broken. Offer to re-run /claude-memory-sync:install to repair it."
  exit 0
fi

origin="$(git -C "$DIR" remote get-url origin 2>/dev/null || true)"
case "$origin" in
  *"$SLUG"*) ;; # installed and consistent — the common case, silent
  *)
    echo "claude-memory-sync: this machine is configured to sync memory to '$SLUG', but ~/.claude's origin is '${origin:-none}' — sync is idle. Offer to re-run /claude-memory-sync:install to repair it."
    ;;
esac
exit 0
