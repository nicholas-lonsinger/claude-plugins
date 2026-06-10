#!/bin/bash
# install-check.sh — SessionStart hook (synchronous).
#
# Verifies memory sync is set up on this machine and, if not, prints a
# one-line nudge. SessionStart stdout is added to Claude's session context,
# so the nudge is what prompts Claude to offer /claude-memory-sync:install —
# nothing is ever changed automatically. The same channel reports a link
# CONFLICT for the current project (memory present both locally and in the
# store), which the sync hook deliberately never resolves on its own.
#
# This check is deliberately separate from claude-sync.sh: the pull hook is
# async (its stdout can't reliably reach session context), so the sync
# script no-ops silently when not installed and this script owns the nudge.
# Matcher-less SessionStart hooks also run on resume/clear/compact, so the
# nudge re-asserts itself across compaction for as long as it stays true.
#
# Always exits 0 — a missing setup must never block a session.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claude-memory-sync-nicholas-lonsinger-plugins}"
MARKER="$DATA/state-repo"

# Store location chosen at install time (see claude-sync.sh); absent on
# pre-0.3.0 installs → the historical default.
DIR="$(cat "$DATA/state-dir" 2>/dev/null)"
[ -n "$DIR" ] || DIR="$HOME/.claude-memory-sync"

# Headless merge session (claude -p inside the merge driver) — stay silent.
[ -n "${CLAUDE_SYNC_ACTIVE:-}" ] && exit 0

# Legacy "uninstalled" sentinel: pre-0.4.0 the uninstall flow wrote this to
# keep an enabled plugin quiet. The uninstall skill now disables or removes
# the plugin instead, so this is only a defensive guard for old data dirs —
# a fresh install still clears it.
[ -f "$DATA/uninstalled" ] && exit 0

if [ ! -f "$MARKER" ]; then
  echo "claude-memory-sync: the plugin is installed and its sync hooks are active, but setup is not complete on this machine — completing it requires running /claude-memory-sync:install (interactive; it asks which private GitHub repo to sync memory to). At the start of the session, briefly explain this and ask the user whether to run it now. If they decline, drop the subject for the rest of the session."
  exit 0
fi

SLUG="$(cat "$MARKER" 2>/dev/null)"
if [ ! -d "$DIR/.git" ]; then
  echo "claude-memory-sync: this machine is configured to sync memory to '$SLUG', but the store repo at $DIR is missing or not a git repo — sync is broken. Offer to re-run /claude-memory-sync:install to repair it."
  exit 0
fi

origin="$(git -C "$DIR" remote get-url origin 2>/dev/null || true)"
case "$origin" in
  *"$SLUG"*) ;; # installed and consistent — fall through to the link check
  *)
    echo "claude-memory-sync: this machine is configured to sync memory to '$SLUG', but the store at $DIR has origin '${origin:-none}' — sync is idle. Offer to re-run /claude-memory-sync:install to repair it."
    exit 0
    ;;
esac

# Read-only link-state check for the current project: surface the one state
# the sync hook refuses to resolve automatically. Identity/classify logic is
# shared with claude-sync.sh via lib-link.sh; nothing here mutates.
MEMSYNC_DIR="$DIR"
. "$SCRIPT_DIR/lib-link.sh"

CWD="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$CWD" ] && [ ! -t 0 ]; then
  CWD="$(sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -n1)"
fi
[ -n "$CWD" ] || exit 0

resolve_identity "$CWD"
[ "$ID_KIND" = skip ] && exit 0
classify_link_state
if [ "$LINK_STATE" = CONFLICT ]; then
  if [ -L "$LINK_SRC" ]; then
    # Identity-mismatch flavor: a symlink is in place but some store entry's
    # recorded .origin doesn't line up with this repo's current origin —
    # a renamed/transferred origin, or a missing/corrupt .origin breadcrumb.
    echo "claude-memory-sync: this project's memory symlink (~/.claude/projects/$ID_SLUG/memory) points at a store entry whose recorded origin no longer matches this repo's origin ($ID_ORIGIN) — likely the GitHub repo was renamed or transferred. Sync will not touch it. Explain this to the user; if it is the same project, offer to update that store entry's .origin file to '$ID_ORIGIN' (other machines then relink automatically). If it is genuinely a different project, the symlink should be removed so a fresh memory dir can be adopted."
  else
    echo "claude-memory-sync: this project's memory exists both locally (~/.claude/projects/$ID_SLUG/memory) and in the store ($LINK_TARGET), or the store entry's identity is ambiguous — it will not be merged automatically. Explain this to the user and offer to reconcile the two interactively (compare the directories, merge distinct facts, then leave the local path as a symlink to the store directory)."
  fi
fi
exit 0
