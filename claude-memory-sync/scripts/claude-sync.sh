#!/bin/bash
# Syncs Claude Code's per-project memory files across machines via the
# store repo at ~/.claude-memory-sync (repo chosen at install time by
# /claude-memory-sync:install). The repo holds one directory per project
# under memory/<name>/, keyed by git origin identity; per machine,
# ~/.claude/projects/<slug>/memory is a directory symlink into the store,
# created and maintained automatically here (see lib-link.sh). ~/.claude
# itself is not a git repo and holds no sync state.
#   pull — SessionStart hook: link/adopt, then fetch + fast-forward, or
#          driver-assisted merge if diverged
#   push — SessionEnd hook: link/adopt, commit local changes, push; merge +
#          retry if the remote moved
#
# Ships in the claude-memory-sync plugin and runs from the versioned plugin
# cache, whose path changes on every version bump. Nothing here may persist
# a cache path: the script self-locates its siblings, and the one persisted
# reference (the merge-driver registration in the store repo's local git
# config) is re-stamped idempotently on every run, so a version bump
# self-heals at the next session.
#
# Conflict intelligence lives in .gitattributes merge drivers
# (claude-merge.sh for markdown), so this script only orchestrates
# link/fetch/commit/merge/push and never resolves content itself.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Mutable state (log, lock, install marker) lives in the plugin's persistent
# data dir, which survives version updates — unlike the cache dir this
# script runs from — and sits outside the store repo, so the `git add -A`
# below can never sweep it into a sync commit.
DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claude-memory-sync-nicholas-lonsinger-plugins}"
mkdir -p "$DATA"
LOG="$DATA/sync.log"
LOCK="$DATA/sync.lock"
MARKER="$DATA/state-repo"

# Store location chosen at install time, persisted alongside the slug marker.
# Absent (pre-0.3.0 installs) → the historical default. Holds an absolute,
# tilde-expanded path; lib-link.sh keys its self-reference guard off it.
DIR="$(cat "$DATA/state-dir" 2>/dev/null)"
[ -n "$DIR" ] || DIR="$HOME/.claude-memory-sync"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$LOG"; }

# Re-entrancy guard: the merge driver runs headless `claude -p`, whose own
# SessionStart/SessionEnd hooks would re-enter this script.
[ -n "${CLAUDE_SYNC_ACTIVE:-}" ] && exit 0
export CLAUDE_SYNC_ACTIVE=1

# Not installed yet → silent no-op. install-check.sh (the synchronous
# SessionStart sibling) owns the "run /claude-memory-sync:install" nudge —
# this hook is async, so its stdout can't reliably reach session context.
# The marker holds the owner/name slug chosen at install; requiring the
# origin to match it keeps this script from ever syncing a repo it doesn't
# own (e.g. ~/.claude-memory-sync replaced by something else entirely).
[ -f "$MARKER" ] || exit 0
SLUG="$(cat "$MARKER" 2>/dev/null)"
[ -n "$SLUG" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Project dir of the session that fired this hook — needed by ensure_link,
# and captured before any cd. CLAUDE_PROJECT_DIR is set for hook commands;
# the hook's stdin JSON carries cwd as a fallback. The -t guard keeps a
# manual terminal invocation from blocking on stdin.
CWD="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$CWD" ] && [ ! -t 0 ]; then
  CWD="$(sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -n1)"
fi
[ -n "$CWD" ] || CWD="$PWD"

MEMSYNC_DIR="$DIR"
. "$SCRIPT_DIR/lib-link.sh"

cd "$DIR" 2>/dev/null || exit 0
[ -d .git ] || exit 0
case "$(git remote get-url origin 2>/dev/null)" in
  *"$SLUG"*) ;;
  *) exit 0 ;;
esac

# Single-flight lock — a DIRECTORY, not a file, on purpose: mkdir is the
# only atomic test-and-set in stock macOS sh (no flock CLI on darwin).
# If another sync is in flight, skip — it or the next session event will
# pick up whatever we'd have done. The lock also serializes link/adopt
# mutations with the git operations below.
if ! mkdir "$LOCK" 2>/dev/null; then
  # Reap a stale lock (>10 min) left by a crashed run, then take it.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# The custom merge driver lives in the store repo's local git config, which
# is per-machine — re-register idempotently so a fresh install gets it on
# first sync and a plugin version bump (which moves this script) re-points it.
if [ "$(git config merge.claude-ai.driver 2>/dev/null)" != "$SCRIPT_DIR/claude-merge.sh %O %A %B %P" ]; then
  git config merge.claude-ai.name "Claude semantic three-way merge"
  git config merge.claude-ai.driver "$SCRIPT_DIR/claude-merge.sh %O %A %B %P"
fi

# Maintain this project's symlink into the store: link, adopt a freshly
# created real memory dir, or heal a broken link — before any commit, so
# an adoption lands in the same sync commit.
ensure_link "$CWD"

commit_local() {
  # Memory files change during normal use; fold them into a sync commit so
  # merges always run against a clean tree.
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git add -A
    git commit -q -m "sync: $(hostname -s) $(date '+%Y-%m-%d %H:%M')" >>"$LOG" 2>&1
  fi
}

merge_remote() {
  # Merge origin/main via the configured drivers. On failure, abort cleanly
  # and defer to the next sync — never leave the repo mid-merge.
  if git merge --no-edit origin/main >>"$LOG" 2>&1; then
    return 0
  fi
  log WARN "merge from origin/main failed; aborted, deferring to next sync"
  git merge --abort >/dev/null 2>&1
  return 1
}

case "${1:-}" in
  pull)
    git fetch -q origin main >>"$LOG" 2>&1 || { log INFO "pull: fetch failed (offline?)"; exit 0; }
    git merge-base --is-ancestor origin/main HEAD 2>/dev/null && exit 0 # already current
    commit_local
    if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
      git merge -q --ff-only origin/main >>"$LOG" 2>&1 && log INFO "pull: fast-forwarded"
    else
      merge_remote && log INFO "pull: merged diverged histories"
    fi
    ;;
  push)
    commit_local
    ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    [ "$ahead" -eq 0 ] && exit 0
    if ! git push -q origin main >>"$LOG" 2>&1; then
      # Remote moved (another machine pushed). Merge with drivers, retry once.
      git fetch -q origin main >>"$LOG" 2>&1 || exit 0
      merge_remote || exit 0
      if git push -q origin main >>"$LOG" 2>&1; then
        log INFO "push: merged remote changes and pushed"
      else
        log WARN "push: still rejected after merge; deferring to next sync"
      fi
    fi
    ;;
  *)
    echo "usage: claude-sync.sh pull|push" >&2
    exit 2
    ;;
esac
exit 0
