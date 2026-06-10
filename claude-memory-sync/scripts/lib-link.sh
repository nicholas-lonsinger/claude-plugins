#!/bin/bash
# lib-link.sh — shared identity + link-state helpers for claude-memory-sync.
#
# Sourced by claude-sync.sh (which also mutates, via ensure_link) and by
# install-check.sh (read-only classification for nudges). Slug and identity
# math lives in one file so the two hooks can never drift apart on it.
#
# The model: the store repo at ~/.claude-memory-sync holds one directory per
# project under memory/<name>/, keyed by git origin identity (or by path
# slug for non-git directories). Per machine, ~/.claude/projects/<slug>/memory
# is a plain directory symlink into the store. These helpers decide, for the
# project a session hook fired in, which of the link states applies and (for
# the mutating caller) carry out the transition.
#
# Conventions: no `set -e` (callers run with `set -u` only); BSD-safe (no
# readlink -f, no GNU find extensions); jq-free.

MEMSYNC_DIR="${MEMSYNC_DIR:-$HOME/.claude-memory-sync}"
MEMSYNC_STORE="$MEMSYNC_DIR/memory"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

# --- pure helpers -----------------------------------------------------------

# normalize_origin <url> → "host/owner/repo", lowercase, scheme/git@/.git
# stripped. Both https://github.com/o/R.git and git@github.com:o/R.git
# normalize to github.com/o/r, so the same repo matches across remote styles.
normalize_origin() {
  printf '%s' "$1" \
    | sed -E 's#^[a-z+]+://##; s#^git@##; s#:#/#; s#\.git/?$##; s#/+$##' \
    | tr '[:upper:]' '[:lower:]'
}

# slug_of_path <abs-path> → the harness's project-slug mangling: every
# character outside [A-Za-z0-9] becomes "-" (verified empirically for
# / . _ + and space; e.g. /Users/x/.claude → -Users-x--claude).
slug_of_path() {
  printf '%s' "$1" | LC_ALL=C sed -e 's/[^A-Za-z0-9]/-/g'
}

# store_name_from_origin <normalized-origin> → "<host-label>-<owner>-<repo>"
# (github.com/nicholas-lonsinger/kernova → github-nicholas-lonsinger-kernova).
store_name_from_origin() {
  snfo_host="${1%%/*}"
  snfo_rest="${1#*/}"
  printf '%s-%s' "${snfo_host%%.*}" "$(printf '%s' "$snfo_rest" | tr '/' '-')"
}

# canon_path <dir> → physical absolute path, empty if it doesn't resolve.
canon_path() {
  ( CDPATH='' cd -- "$1" 2>/dev/null && pwd -P )
}

# dir_has_md <dir> → success when the dir holds at least one real memory
# file (flat *.md; .origin and .DS_Store don't count).
dir_has_md() {
  [ -d "$1" ] || return 1
  find "$1" -maxdepth 1 -type f -name '*.md' -print -quit 2>/dev/null | grep -q .
}

# dirs_identical <dir-a> <dir-b> → success when both dirs hold the same files
# with byte-identical contents, ignoring store-internal bookkeeping (.origin)
# and macOS cruft (.DS_Store). Lets the link state machine tell a genuinely
# divergent CONFLICT apart from a redundant copy — e.g. an uninstall→reinstall
# cycle that restored a local dir while the store still holds the same content.
# -x (exclude by basename glob) is honored by both BSD and GNU diff.
dirs_identical() {
  [ -d "$1" ] && [ -d "$2" ] || return 1
  diff -rq -x .origin -x .DS_Store "$1" "$2" >/dev/null 2>&1
}

# find_store_dir_by_origin <normalized-origin> → echoes the store dir whose
# .origin matches, if any. .origin is the source of truth for identity, so a
# hand-renamed store dir is still found (and healed to) rather than
# duplicated by a fresh adoption.
find_store_dir_by_origin() {
  for fsd_d in "$MEMSYNC_STORE"/*/; do
    [ -d "$fsd_d" ] || continue
    if [ "$(head -n1 "${fsd_d}.origin" 2>/dev/null)" = "$1" ]; then
      printf '%s' "${fsd_d%/}"
      return 0
    fi
  done
  return 1
}

# --- identity resolution ----------------------------------------------------

# resolve_identity <cwd> — sets:
#   ID_KIND   git | path | skip
#   ID_ORIGIN normalized origin URL (git kind only)
#   ID_PATH   the path the identity keys on (main checkout root, or cwd)
#   ID_NAME   store dir name under memory/
#   ID_SLUG   ~/.claude/projects/<slug> the harness uses for this project
#
# The harness keys auto memory by the MAIN repo root (all worktrees and
# subdirectories share it), so for git projects both the slug and the
# identity come from the main checkout root, resolved via --git-common-dir.
resolve_identity() {
  rid_cwd="$1"
  ID_KIND=path ID_ORIGIN='' ID_PATH='' ID_NAME='' ID_SLUG=''
  case "$rid_cwd" in
    "$MEMSYNC_DIR" | "$MEMSYNC_DIR"/*)
      # A session inside the store repo itself must never sync into itself.
      ID_KIND=skip
      return 0
      ;;
  esac
  rid_root=''
  # ~/.claude is forced to path keying: a stray .git there (e.g. left over
  # from the pre-0.2.0 design) must not key Claude's own state dir by origin.
  if [ "$rid_cwd" != "$HOME/.claude" ] \
    && git -C "$rid_cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    rid_common="$(git -C "$rid_cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    case "$rid_common" in
      */.git) rid_root="${rid_common%/.git}" ;;
      *) rid_root='' ;; # bare or exotic layout — fall back to path keying
    esac
  fi
  if [ -n "$rid_root" ]; then
    rid_origin_raw="$(git -C "$rid_root" remote get-url origin 2>/dev/null || true)"
    if [ -n "$rid_origin_raw" ]; then
      ID_KIND=git
      ID_ORIGIN="$(normalize_origin "$rid_origin_raw")"
      ID_PATH="$rid_root"
      ID_NAME="$(store_name_from_origin "$ID_ORIGIN")"
      ID_SLUG="$(slug_of_path "$rid_root")"
      return 0
    fi
    # Git repo without an origin remote: key by the main root's path.
    ID_PATH="$rid_root"
  else
    ID_PATH="$rid_cwd"
  fi
  ID_NAME="$(slug_of_path "$ID_PATH")"
  ID_SLUG="$ID_NAME"
}

# --- link state machine -----------------------------------------------------

# classify_link_state — after resolve_identity, sets:
#   LINK_SRC    ~/.claude/projects/<slug>/memory (what the harness reads)
#   LINK_TARGET store dir this project should map to
#   LINK_STATE  one of:
#     SKIP             self-reference guard fired
#     LINKED           correct symlink already in place
#     LINK_ONLY        no local memory; store dir exists → just link
#     ADOPT            real local memory, no store dir → move in + link
#     ADOPT_INTO_EMPTY real local memory, store dir has no payload → same
#     HEAL             dangling/wrong symlink, or empty real dir shadowing
#                      an existing store dir → replace with correct link
#     HEAL_REDUNDANT   real local memory byte-identical to an existing store
#                      dir (e.g. an uninstall→reinstall cycle) → drop the
#                      redundant copy and relink; loses no unique content
#     CONFLICT         both sides have DISTINCT payload, identity is
#                      ambiguous, or the existing symlink points at a
#                      payload-bearing store dir the current identity no
#                      longer selects (renamed/transferred origin) — never
#                      resolved automatically (install-check nudges)
#     NOOP             nothing to do yet (no memory anywhere)
classify_link_state() {
  LINK_STATE=NOOP
  if [ "$ID_KIND" = skip ]; then
    LINK_STATE=SKIP
    return 0
  fi
  LINK_SRC="$CLAUDE_PROJECTS_DIR/$ID_SLUG/memory"
  LINK_TARGET="$MEMSYNC_STORE/$ID_NAME"
  if [ "$ID_KIND" = git ]; then
    cls_existing="$(find_store_dir_by_origin "$ID_ORIGIN" || true)"
    if [ -n "$cls_existing" ]; then
      LINK_TARGET="$cls_existing"
    elif [ -e "$LINK_TARGET" ] || [ -L "$LINK_TARGET" ]; then
      # The computed name is taken but its .origin names a different repo
      # (or is missing/corrupt). Never adopt into ambiguous identity.
      LINK_STATE=CONFLICT
      return 0
    fi
  fi
  if [ -L "$LINK_SRC" ]; then
    cls_cur="$(canon_path "$LINK_SRC")"
    if [ -d "$LINK_TARGET" ] && [ "$cls_cur" = "$(canon_path "$LINK_TARGET")" ]; then
      LINK_STATE=LINKED
      return 0
    fi
    # A live symlink into a payload-bearing store dir that identity no longer
    # selects (and no replacement target exists) is the signature of a renamed
    # or transferred origin: the old store dir still holds this project's
    # memory under its old identity. Healing would drop the link and let a
    # fresh adoption split the memory in two — surface CONFLICT instead; the
    # interactive fix is updating that dir's .origin to the new identity,
    # after which every machine relinks to it by breadcrumb.
    if [ ! -d "$LINK_TARGET" ]; then
      case "$cls_cur" in
        "$MEMSYNC_STORE"/*)
          if dir_has_md "$cls_cur"; then
            LINK_STATE=CONFLICT
            return 0
          fi
          ;;
      esac
    fi
    LINK_STATE=HEAL
    return 0
  fi
  if [ -d "$LINK_SRC" ]; then
    if dir_has_md "$LINK_SRC"; then
      if [ ! -d "$LINK_TARGET" ]; then
        LINK_STATE=ADOPT
      elif dir_has_md "$LINK_TARGET"; then
        if dirs_identical "$LINK_SRC" "$LINK_TARGET"; then
          LINK_STATE=HEAL_REDUNDANT # local is a redundant copy of the store
        else
          LINK_STATE=CONFLICT
        fi
      else
        LINK_STATE=ADOPT_INTO_EMPTY
      fi
    elif [ -d "$LINK_TARGET" ]; then
      LINK_STATE=HEAL # empty real dir shadowing an existing store dir
    fi
    return 0
  fi
  if [ -e "$LINK_SRC" ]; then
    LINK_STATE=CONFLICT # a regular file where a dir/link belongs — hands off
    return 0
  fi
  [ -d "$LINK_TARGET" ] && LINK_STATE=LINK_ONLY
}

# --- mutations (claude-sync.sh only) ----------------------------------------

# write_origin_breadcrumb — stamp LINK_TARGET/.origin with this project's
# identity (idempotent). Non-git dirs get a self-describing path: line.
write_origin_breadcrumb() {
  if [ "$ID_KIND" = git ]; then
    wob="$ID_ORIGIN"
  else
    wob="path:$ID_PATH"
  fi
  [ "$(head -n1 "$LINK_TARGET/.origin" 2>/dev/null)" = "$wob" ] \
    || printf '%s\n' "$wob" >"$LINK_TARGET/.origin"
}

# apply_link_state — carry out the classified transition. Deliberately
# non-destructive: mv -n only, rm only on symlinks, verified-empty dirs, or
# (HEAL_REDUNDANT) a local dir re-confirmed byte-identical to the version-
# controlled store it links to, so nothing unique is ever dropped. Anything
# surprising is left in place for the next run (or the CONFLICT nudge). Always
# returns 0 — sync must never fail a session over a link.
apply_link_state() {
  case "$LINK_STATE" in
    LINKED | NOOP | SKIP | CONFLICT) return 0 ;;
    LINK_ONLY)
      mkdir -p "$(dirname "$LINK_SRC")" 2>/dev/null
      ln -s "$LINK_TARGET" "$LINK_SRC" 2>/dev/null
      ;;
    HEAL)
      if [ -L "$LINK_SRC" ]; then
        rm -f "$LINK_SRC" 2>/dev/null
      elif [ -d "$LINK_SRC" ]; then
        dir_has_md "$LINK_SRC" && return 0 # re-guard: never drop payload
        rm -f "$LINK_SRC/.DS_Store" 2>/dev/null
        rmdir "$LINK_SRC" 2>/dev/null || return 0
      fi
      [ -d "$LINK_TARGET" ] && ln -s "$LINK_TARGET" "$LINK_SRC" 2>/dev/null
      ;;
    HEAL_REDUNDANT)
      # Local is a payload-bearing dir that exactly duplicates the store
      # (typical after an uninstall→reinstall cycle). Re-verify byte-identity
      # immediately before removing anything — if the tree changed under us
      # and they no longer match, bail and leave both sides for CONFLICT.
      dirs_identical "$LINK_SRC" "$LINK_TARGET" || return 0
      rm -rf "$LINK_SRC" 2>/dev/null
      ln -s "$LINK_TARGET" "$LINK_SRC" 2>/dev/null
      ;;
    ADOPT | ADOPT_INTO_EMPTY)
      mkdir -p "$LINK_TARGET" 2>/dev/null || return 0
      write_origin_breadcrumb
      find "$LINK_SRC" -mindepth 1 -maxdepth 1 -exec mv -n {} "$LINK_TARGET"/ \; 2>/dev/null
      if [ -n "$(find "$LINK_SRC" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
        return 0 # name collision left stragglers — next run sees CONFLICT
      fi
      rmdir "$LINK_SRC" 2>/dev/null || return 0
      ln -s "$LINK_TARGET" "$LINK_SRC" 2>/dev/null
      ;;
  esac
  return 0
}

# ensure_link <cwd> — the one-call entry point for claude-sync.sh. Runs
# inside the sync lock so adoption can't race a concurrent commit. The
# caller provides log(); states that change nothing stay quiet.
ensure_link() {
  [ -n "${1:-}" ] || return 0
  resolve_identity "$1"
  [ "$ID_KIND" = skip ] && return 0
  classify_link_state
  case "$LINK_STATE" in
    LINKED | NOOP) : ;;
    *) log INFO "link: $LINK_STATE slug=$ID_SLUG name=$ID_NAME" ;;
  esac
  apply_link_state
}
