---
name: fix
description: Fix GitHub issues by number or query. Pass issue numbers, or instructions like "select all issues whose label begins with 'review-debt'". Add --merge to auto-merge each PR, --follow-up to also queue issues filed during the run (e.g. deferred code-review findings)
argument-hint: "<issue-number(s) or selection instructions> [--merge] [--follow-up [depth]]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Glob
  - Grep
  - Read
  - Task
  - SendMessage
---

# Fix GitHub Issue(s) — Orchestrator

> **Recommended: pair long runs with `/goal`.** At the start of a multi-issue or `--merge` run, suggest (once, briefly) that the user set a completion goal, e.g. `/goal every issue in <input> (plus any follow-up issues the run spawns) has a terminal outcome — merged, closed, or blocked with a posted reason — and the Fix-Issue Summary table has been printed; or stop after 30 turns`. The goal evaluator re-prompts on every turn end until the summary exists, so a run cannot die silently mid-queue even if a notification is lost.

You are an orchestrator that coordinates issue-fixing agents. You select issues, launch an `issues:issue-fixer` agent for each one, and manage the serial workflow. Each agent handles its issue end-to-end: an Opus planning subagent verifies the issue still applies and designs the fix, then the agent implements it, creates a PR, and runs `/code-review medium --fix`. With `--merge` the agent also merges the PR; otherwise it leaves the PR open for the user and moves on.

## Input

$ARGUMENTS

## Flags

Check the input for these flags before interpreting the rest as issue numbers or a selection query:

- **`--merge`** — after a successful code review, the agent merges the PR and runs post-merge cleanup. Without this flag, the agent stops after the review: it leaves the PR open, returns to the default branch, and the run moves on to the next issue, leaving all PRs for the user to merge.

- **`--follow-up [depth]`** (alias: `--recursive`) — issues filed *during* the run also get fixed. When a completed agent reports `DEFERRED_ISSUES` (issues created for deferred code-review findings or other follow-up work), append those numbers to the work queue instead of leaving them for a future run. Without this flag, report deferred issues in the summary but do not process them.

  **Depth cap:** the optional number bounds how many generations of follow-ups to chase (default **2**). Issues from the original input are depth 0; issues they spawn are depth 1, and so on. Track each queued issue's depth; when an agent at the max depth reports `DEFERRED_ISSUES`, do not queue them — list them in the summary as unprocessed, noting the cap was hit. `--follow-up 1` chases only direct spawns; a higher number chases deeper.

Regardless of flags, maintain a **processed set** of issue numbers handled this run (whatever the outcome). Never queue or process a number already in it. This prevents re-picking an issue left open in pr-only mode (issues only auto-close on merge) and, together with the depth cap, is the runaway guard for follow-up mode.

## Agent Model

By default, launch the `issues:issue-fixer` agent with `model: "sonnet"` and no effort override (it inherits the session's effort level). If the user explicitly requests a different model (e.g., "use opus for the agents"), use that model instead. This keeps the orchestrator on whatever model it was invoked with while the implementing agent defaults to Sonnet for cost efficiency.

Internally, the agent pins its planning subagent to Opus — planning and issue-verification judgment get the stronger model while implementation stays on Sonnet. A user model override changes the implementing agent, not the planner.

## Setup

Determine the GitHub username for assigning issues back:

```
gh api user -q .login
```

## Issue Selection

**If the input is one or more issue numbers** (e.g., `42`, `451-455`, `12 14 17`), the work queue is those numbers, ascending. Process them one at a time through the workflow below; in `--follow-up` mode, also append each completed agent's `DEFERRED_ISSUES` to the queue (skipping the processed set). Stop when the queue is empty.

**If the input is a selection query** (e.g., `select all issues whose label begins with 'review-debt'`), operate in a loop:

1. Fetch the list of matching open issues, sorted by issue number ascending (oldest first).
   Use `gh issue list` with appropriate flags (`--label`, `--search`, `--state open`, `--json number,title,labels,body`, `--jq`, etc.).
2. **Skip processed issues.** Drop any issue already in the processed set (e.g., handled in pr-only mode and still open awaiting merge).
3. **Check dependencies.** For each issue (oldest first), inspect the issue body and comments for dependency references ("blocked by #N", "depends on #N", linked issues). If the blocking issue is still open, skip it for now and move to the next eligible issue.
4. Pick the first eligible (oldest, unblocked) issue.
5. Process it through the workflow below.
6. After the issue is handled, **re-fetch matching open issues from scratch** (not from a cached list — new issues may have been filed, previously blocked issues may now be unblocked). Repeat from step 2.
7. Continue until no eligible matching open issues remain.

In `--follow-up` mode, deferred issues reported by completed agents join the queue **even if they don't match the selection query** — being spawned by this run is what qualifies them.

## Per-Issue Workflow

### Step 1: Launch the Issue-Fixer Agent

Launch the `issues:issue-fixer` agent in the foreground — pass `run_in_background: false` explicitly (agents default to background) — with `model: "sonnet"` (or the user-specified model) and the issue number and GitHub username. **Do not use `isolation: "worktree"`** — the agent works in the main repo tree and creates its branch in-place.

```
Fix GitHub issue #<NUMBER>.
GitHub username for assigning issues: <GITHUB_USERNAME>
Merge mode: <"merge" if --merge was passed, otherwise "pr-only">
CI wait script: ${CLAUDE_PLUGIN_ROOT}/scripts/wait-for-ci.sh
```

Wait for the agent to complete. The agent has its Opus planner verify the issue still applies and design the fix, implements it, creates a PR, runs `/code-review medium --fix`, and addresses PR comments. In merge mode it then merges; in pr-only mode it leaves the PR open and returns to the default branch.

### Step 2: Handle the Result

Based on the agent's return status:

- **`closed-completed`** or **`closed-not-planned`** — Issue was already resolved, stale, or judged not worth fixing. The agent posted its reasoning on the issue. Record the outcome and move to the next issue.
- **`research`** — Issue was research-only. Agent posted findings and assigned to user. Move to the next issue.
- **`blocked`** — Agent could not complete the fix. Log the reason. Move to the next issue.
- **`merged`** — PR was created, reviewed, and merged. Record success.
- **`pr-created`** — (pr-only mode) PR was created and reviewed but intentionally left open. Record the PR number for the summary and move on.
- **Non-terminal return (no `STATUS:` line)** — the agent ended without one of the statuses above, typically saying it is "waiting" for CI or a background task. The agent is gone: a completed subagent is never re-invoked, and notifications from tasks it orphaned may never be delivered. Do **not** end your turn to wait for one. Recover actively, in this order:
  1. Check ground truth yourself: `gh pr view <PR> --json state,headRefOid,mergeStateStatus,statusCheckRollup` and `gh issue view <N> --json state`.
  2. If everything left is mechanical — waiting for CI, merging, cleanup — finish it yourself with **blocking foreground** Bash calls. For the CI wait, run the plugin's script unpiped: `"${CLAUDE_PLUGIN_ROOT}/scripts/wait-for-ci.sh" <PR> --timeout 540` (re-issue on exit 3; it verifies the head SHA and the full rollup itself). Merge per project conventions only on exit 0.
  3. Only if substantive work remains (unfixed review findings, failing checks needing code changes), resume the agent once via SendMessage with explicit instructions to finish synchronously and return a terminal `STATUS:`. If it returns non-terminal a second time, take over per step 2 or record the issue as `blocked` — do not resume it again.

For `merged` and `pr-created` results that list `DEFERRED_ISSUES`: in `--follow-up` mode, append any numbers not already in the processed set to the work queue at the current issue's depth + 1 (unless that exceeds the depth cap); otherwise just note them for the summary report.

### Step 3: Compact and Loop (if processing multiple issues)

Before looping to the next issue, run `/compact` to free up context window space:

```
/compact Retain: (1) the full orchestrator instructions from /issues:fix; (2) the original input including any flags: "$ARGUMENTS"; (3) the list of issues processed so far and their outcomes; (4) the remaining work queue, including any follow-up issues appended from DEFERRED_ISSUES and each queued issue's depth; (5) the GitHub username. Drop per-file diffs, build output, review details, and agent transcripts from completed issues.
```

Then go back to Issue Selection and re-fetch matching issues.

## Summary Report

After all issues are processed (or no eligible issues remain), report a summary:

```
## Fix-Issue Summary

| Issue | Status | PR | Notes |
|-------|--------|----|-------|
| #12   | merged | #45 | Fixed feed parsing bug |
| #14   | pr-created | #46 | PR open, awaiting your merge |
| #15   | closed | —  | Already fixed in recent commit |
| #17   | closed | — | Stale — code it referenced was removed |
| #18   | blocked | — | Needs clarification on expected behavior |
| #20   | research | — | Posted analysis and assigned to user |
| #23   | merged | #48 | Follow-up from #12's review (queued via --follow-up) |
```

Mark follow-up issues as such in the notes. Without `--follow-up`, list any reported `DEFERRED_ISSUES` below the table as unprocessed follow-ups the user may want to run next.

## Important Notes

- Process issues **one at a time**, serially. Do not launch multiple agents in parallel.
- **Never end your turn while work is pending.** A run ends only by printing the Summary Report — with the queue empty and every agent result terminal. Ending a turn to "wait for a notification" is how runs silently die: if you are ever tempted to write "waiting for…", switch to a blocking foreground wait or take the remaining steps over yourself (see the non-terminal branch in Step 2).
- Always re-fetch issues between iterations — the list may have changed.
- Respect issue dependencies. Do not process an issue that is blocked by another open issue.
- An agent closing an issue as stale or not worth fixing is a valid, successful outcome — do not re-open or retry it.
- With `--merge`, merges do not need user confirmation: the plugin ships a PreToolUse hook that auto-approves `gh pr merge` for the `issues:issue-fixer` agent, so runs proceed unattended in accept-edits mode. Without `--merge`, the agent never attempts a merge.
- In pr-only mode, each agent branches from the default branch, so open PRs from earlier in the run are not included in later fixes. PRs that touch the same code may conflict at merge time — that is expected and resolved when the user merges.
- If a fix requires changes that are too large or risky, the agent will comment and assign back. Do not override this.
