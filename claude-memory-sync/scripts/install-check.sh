#!/bin/bash
# install-check.sh — SessionStart hook (synchronous).
#
# Verifies the whole install chain on this machine — base install, store
# health, the current project's link state, and the user-scope import chain
# (store user/ files → stamped instruction hub + user/ symlink → @ line in
# the user's own CLAUDE.md) — and prints a one-line nudge for the first gap
# found.
# SessionStart stdout is added to Claude's session context, so the nudge is
# what prompts Claude to offer /claude-memory-sync:install — nothing is
# ever changed automatically. The same channel reports a link CONFLICT for
# the current project (memory present both locally and in the store), which
# the sync hook deliberately never resolves on its own. The dividing line:
# plugin-owned machine-local state self-heals silently in claude-sync.sh;
# anything user-owned or consent-gated is only ever nudged about here.
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

if [ -n "$CWD" ]; then
  resolve_identity "$CWD"
  if [ "$ID_KIND" != skip ]; then
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
      exit 0
    fi
  fi
fi

# User-scope import chain: store user/ files → stamped instruction hub →
# @ line in the user's own CLAUDE.md. These checks double as the upgrade
# path — a machine installed before 0.5.0 has none of the pieces, and every
# gap has the same fix, the idempotent install skill — and they re-assert
# every session, so an accidentally edited-out @ line gets caught. Ordered
# after the CONFLICT check above: a divergence risk outranks dormant
# context. Project-independent, so they run even without a CWD.
if [ ! -f "$DIR/user/CLAUDE.md" ] || [ ! -f "$DIR/user/MEMORY.md" ]; then
  echo "claude-memory-sync: project-memory sync is active, but the store at $DIR has no user-scope files (user/CLAUDE.md + user/MEMORY.md), so synced global instructions and memories are not set up. Offer to run /claude-memory-sync:install to enable them (idempotent — the existing project-memory setup is untouched). If the user declines, drop the subject for the rest of the session."
  exit 0
fi
if [ ! -f "$DATA/CLAUDE.md" ]; then
  echo "claude-memory-sync: the store has user-scope files, but this machine's instruction hub ($DATA/CLAUDE.md) is missing, so synced global instructions and memories are not active here. Offer to run /claude-memory-sync:install to finish enabling them (idempotent). If the user declines, drop the subject for the rest of the session."
  exit 0
fi
# A missing or mistargeted $DATA/user symlink self-heals in claude-sync.sh;
# a real directory in its place is the one state the hook refuses to touch.
if [ -e "$DATA/user" ] && [ ! -L "$DATA/user" ]; then
  echo "claude-memory-sync: $DATA/user should be a symlink into the store ($DIR/user) but is a real directory, so synced global instructions and memories may be stale or shadowed. Sync will not touch it. Explain this to the user and offer to reconcile interactively (compare it with $DIR/user, merge anything unique into the store, then replace it with the symlink)."
  exit 0
fi
if ! grep -qF "@$DATA/CLAUDE.md" "$HOME/.claude/CLAUDE.md" 2>/dev/null; then
  echo "claude-memory-sync: ~/.claude/CLAUDE.md does not import the synced user-scope context — the line '@$DATA/CLAUDE.md' is missing, so synced global instructions and memories will not load. Explain this and, with the user's consent (it is their file), offer to re-add that line. If they decline, drop the subject for the rest of the session."
  exit 0
fi
exit 0
