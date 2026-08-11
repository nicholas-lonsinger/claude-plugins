---
name: wait-ci
description: >-
  Block until a pull request's CI is verifiably green before merging or
  building on it. Use after pushing to a PR branch — it confirms the push
  actually landed on the remote, waits for the checks to register and finish,
  and renders a trustworthy verdict, where a bare `gh pr checks --watch` can
  race a fresh push and return a false green.
allowed-tools:
  - Bash
---

# Wait for a PR's CI

A watch started right after a push races three things: the push itself (a
bare `git push` with mismatched local/remote branch names silently no-ops),
the API's view of the PR head, and check registration (zero checks reported
reads as success). The script owns the whole choreography — pin the expected
SHA, verify the push landed via `git ls-remote`, barrier on the required
checks registering, watch, then verify the final rollup directly.

## Run it

After pushing, from inside the repository, as a **background** Bash command
(CI regularly outlives the foreground timeout; the exit re-invokes you):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/wait-for-ci.sh" <pr-number>
```

The PR number defaults to the current branch's PR, and the expected head SHA
to `git rev-parse HEAD` — run it from the worktree you pushed from, or pass
`--sha` explicitly. `--timeout <seconds>` bounds one invocation (default
3600), `--repo <owner/repo>` and `--remote <name>` cover non-default setups.

## Reading the result

Progress goes to stderr; the last stdout line is machine-readable
(`wait-for-ci: verdict=... pr=... sha=...`). Branch on the exit code:

| Exit | Meaning | Next action |
|---|---|---|
| 0 | Verified green on the expected SHA | Safe to merge / proceed |
| 1 | Usage or environment error | Fix the invocation |
| 2 | A gating check failed, was cancelled, or timed out | `gh run view <run-id> --log-failed`, fix, push, re-run |
| 3 | Deadline expired, checks still pending | Re-run to keep waiting |
| 4 | The push never landed on the remote | Push with an explicit refspec (`git push origin HEAD:<branch>`), re-run |
| 5 | PR head moved mid-wait (a new push happened) | Re-run against the new head |
| 6 | PR is not open (merged or closed) | Stop — nothing to wait for |

Merge only on exit 0. Do not substitute a hand-rolled `gh pr checks --watch`
or a sleep loop: the watch's exit code alone is not a verdict (it is 0 for
"no checks registered yet" and for cancelled runs), and improvising the
choreography reintroduces exactly the races the script exists to close.
