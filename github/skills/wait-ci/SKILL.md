---
name: wait-ci
description: >-
  Wait for a pull request's CI to finish and verify it is genuinely green —
  required checks passed on the pushed head SHA — before merging or reporting
  status. Use whenever work depends on a PR's checks completing: merging after
  a push, "merge when green", watching or babysitting CI.
allowed-tools:
  - Bash
---

# Wait for CI (verified green)

One script owns the entire wait-for-green choreography: head-SHA pinning, the
checks-registered barrier, one unpiped watch, and the final rollup
verification. Do not hand-roll any of those steps, and never trust
`gh pr checks --watch`'s exit code on its own — it is 0 for "no checks yet"
and for cancelled runs. The script exists because of exactly those traps.

## Run it

After the push has been issued, from the PR's repo:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/wait-for-ci.sh" <pr-number>
```

- **Main-loop session:** run it with `run_in_background: true`. The harness
  wakes you when it exits — do not poll it and do not schedule wakeups for it
  (at most a long fallback heartbeat if you'd otherwise idle).
- **Subagent** (background Bash forbidden): run it in the **foreground** with
  Bash `timeout: 600000` and pass `--timeout 540`. If it exits 3 (still
  pending), re-issue the same call until it returns a different code — it is
  idempotent and resumes the wait.
- **Never pipe it** (`| tee`, `| tail`, `$(...)`) — pipes mask the exit code.
  Read the exit code and its final `wait-for-ci: verdict=...` line as-is.
- `--sha` defaults to `git rev-parse HEAD`; pass it explicitly if the working
  tree might not be on the PR's branch. `--repo owner/repo` targets a PR from
  outside its checkout.

## Acting on the result

| Exit | Meaning | What to do |
|------|---------|------------|
| 0 | Verified green | Safe to merge |
| 2 | Definitively not green (failed/cancelled check) | Investigate the named checks; fix or report — do not merge |
| 3 | Deadline hit, checks still pending | Re-run to keep waiting |
| 4 | PR head never matched the expected SHA | The push likely didn't land (a bare `git push` with mismatched local/remote branch names silently no-ops) — re-push with an explicit refspec, then re-run |
| 5 | Head moved mid-wait (a new push) | Re-run against the new head |
| 6 | PR is not open (merged/closed) | Nothing to wait for — check `gh pr view` |
| 1 | Usage or environment error | Read stderr |

Merge **only** on exit 0.
