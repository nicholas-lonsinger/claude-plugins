#!/usr/bin/env bash
# freshen-main.sh — fetch with prune, then fast-forward the checkout that holds
# the remote's default branch onto its remote-tracking ref.
#
# Exists for worktree sessions. A squash merge lands on the remote without
# moving the local default-branch ref, and a session running inside a worktree
# cannot advance a branch checked out in another one: no in-worktree git
# command moves it, and Claude Code's worktree-isolation guard refuses ad-hoc
# `git -C <other-checkout>` commands. This script is the vetted route — one
# fetch, one fast-forward, nothing else.
#
# Quiet and best-effort. It prints one line when it moves the branch and exits
# 0 silently otherwise: the branch is already current, it has diverged from the
# remote, no worktree has it checked out, or that worktree has local changes a
# fast-forward would overwrite. Exit 1 means the fetch itself failed (offline,
# no such remote) or an argument was bad.

set -uo pipefail

REMOTE=origin

usage() {
    cat <<'EOF'
Usage: freshen-main.sh [--remote <name>]

Fetches (with prune) and fast-forwards the checkout holding the remote's
default branch. Prints one line when it moves the branch, nothing otherwise.
Exit 0 unless the fetch fails or an argument is bad (1).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --remote) REMOTE="${2:?--remote needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'freshen-main: unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

git fetch --prune --quiet "$REMOTE" 2>/dev/null || exit 1

# The default branch, read from the remote's cached HEAD symref. A clone made
# with --single-branch, or a remote added by hand, has no refs/remotes/<remote>/HEAD
# until something sets it; --auto asks the remote and caches the answer.
default_ref=$(git symbolic-ref -q --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null)
if [ -z "$default_ref" ]; then
    git remote set-head "$REMOTE" --auto --quiet 2>/dev/null
    default_ref=$(git symbolic-ref -q --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null)
fi
[ -n "$default_ref" ] || exit 0
branch=${default_ref#"$REMOTE/"}

# The worktree with that branch checked out, which is not necessarily the
# primary one. A bare primary and a detached HEAD (mid-rebase, or a manually
# created worktree) both lack a `branch` line, so neither ever matches.
root=$(git worktree list --porcelain 2>/dev/null | awk -v want="refs/heads/$branch" '
    /^worktree / { path = substr($0, 10) }
    /^branch /   { if (substr($0, 8) == want) { print path; exit } }
')
[ -n "$root" ] || exit 0

git merge-base --is-ancestor "$default_ref" "refs/heads/$branch" 2>/dev/null && exit 0

git -C "$root" merge --ff-only --quiet "$default_ref" 2>/dev/null \
    && printf 'freshen-main: fast-forwarded %s in %s\n' "$branch" "$root"
exit 0
