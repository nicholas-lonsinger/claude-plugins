---
name: freshen-main
description: >-
  Fast-forward the local default branch onto the remote after a pull request
  merges. Use right after confirming a squash merge landed, and whenever the
  local default branch is stale — especially from inside a git worktree, where
  the branch is checked out in another directory and the worktree-isolation
  guard blocks a direct `git -C` against it.
allowed-tools:
  - Bash
---

# Freshen the default branch

A squash merge advances the branch on the remote and leaves the local ref
where it was. From a worktree session that ref cannot be moved by hand: it is
checked out in another directory, so no in-worktree git command touches it,
and ad-hoc `git -C <other-checkout>` is refused by the worktree-isolation
guard. One script owns the operation instead.

## Run it

From anywhere inside the repository:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/freshen-main.sh"
```

Add `--remote <name>` for a repo whose upstream is not `origin`.

Run it after `gh pr view <N> --json state -q .state` reports `"MERGED"` — not
before. Merging and freshening are separate steps, and a fast-forward attempted
against a PR that has not actually merged silently does nothing.

## Reading the result

It is quiet and best-effort by design.

| Output | Meaning |
|---|---|
| `freshen-main: fast-forwarded <branch> in <path>` | The local branch moved |
| Nothing, exit 0 | Nothing to do: already current, diverged from the remote, not checked out in any worktree, or that checkout has local changes a fast-forward would overwrite |
| Exit 1 | The fetch failed (offline, no such remote) or an argument was bad |

Silence is a normal outcome, not a failure — do not retry it, and do not
reach for raw git to force the result it declined to produce. A diverged or
dirty default branch is a situation for the user to resolve.

## Do not hand-roll it

Never substitute `git -C <path> merge`, `git fetch origin main:main`, or a
`cd` into the other checkout. The guard exists to keep a worktree session
from mutating a checkout it is not scoped to; this script is the narrow,
reviewed exception to it, and widening that exception one command at a time
defeats it.
