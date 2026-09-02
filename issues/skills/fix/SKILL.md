---
name: fix
description: Fix GitHub issues by number or query. Pass issue numbers, or instructions like "select all issues whose label begins with 'review-debt'". Add --merge to auto-merge each PR, --follow-up to also queue issues filed during the run (e.g. deferred review findings), --review-level to pin the code-review effort level, --review-model to pin the reviewer agent's model
argument-hint: "<issue-number(s) or selection instructions> [--merge] [--follow-up [depth]] [--review-level <low|medium|high|xhigh|max>] [--review-model <sonnet|opus|fable>]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Glob
  - Grep
  - Read
  - Task
  - Skill
  - SendMessage
---

# Fix GitHub Issue(s) — Orchestrator

> **Recommended: pair long runs with `/goal`.** At the start of a multi-issue or `--merge` run, suggest (once, briefly) that the user set a completion goal, e.g. `/goal every issue in <input> (plus any follow-up issues the run spawns) has a terminal outcome — merged, closed, or blocked with a posted reason — and the Fix-Issue Summary table has been printed; or stop after 30 turns`. The goal evaluator re-prompts on every turn end until the summary exists, so a run cannot die silently mid-queue even if a notification is lost.

You are an orchestrator that coordinates issue-fixing agents. For each issue you run a pipeline of specialized subagents, each sized to its job:

1. **`issues:issue-planner`** (Opus, pinned in its definition) verifies the issue still applies, designs the fix, and sizes the work.
2. **`issues:issue-implementer`** (model chosen from the planner's complexity call) implements the plan, builds, tests, and opens a PR — then pauses.
3. **`issues:issue-reviewer`** (model sized to the diff) reviews the PR independently of its author — built-in `/code-review`, plus Codex and adversarial Codex reviews fanned out in parallel when the codex plugin is installed — verifies every finding, and files issues for out-of-scope ones.
4. **`issues:issue-verifier`** (optional) drives the actual app to confirm user-facing behavior.
5. The implementer is **continued via SendMessage** to apply confirmed findings and finalize: merge the PR (with `--merge`) or leave it open.

You stay light: selection, sequencing, relaying results between agents, and the summary. Do not read diffs, review code, or implement anything yourself.

## Input

$ARGUMENTS

## Flags

Check the input for these flags before interpreting the rest as issue numbers or a selection query:

- **`--merge`** — after a clean review, the implementer merges the PR and runs post-merge cleanup. Without this flag, the implementer stops after applying review findings: it leaves the PR open, returns to the default branch, and the run moves on to the next issue, leaving all PRs for the user to merge.

- **`--follow-up [depth]`** (alias: `--recursive`) — issues filed *during* the run also get fixed. When a completed pipeline reports `DEFERRED_ISSUES` (issues created for deferred review findings or other follow-up work), append those numbers to the work queue instead of leaving them for a future run. Without this flag, report deferred issues in the summary but do not process them.

  **Depth cap:** the optional number bounds how many generations of follow-ups to chase (default **2**). Issues from the original input are depth 0; issues they spawn are depth 1, and so on. Track each queued issue's depth; when a pipeline at the max depth reports `DEFERRED_ISSUES`, do not queue them — list them in the summary as unprocessed, noting the cap was hit. `--follow-up 1` chases only direct spawns; a higher number chases deeper.

- **`--review-level <level>`** — pins the effort level of the reviewer's built-in `/code-review` pass for every issue this run. Accepts `low`, `medium`, `high`, `xhigh`, or `max`. Without the flag, each review uses the planner's `SUGGESTED_REVIEW_LEVEL`. Reject `ultra` with a one-line explanation and no fallback: it is a user-triggered, billed cloud review that an agent cannot launch.

- **`--review-model <model>`** — pins the reviewer agent's model for every issue this run (`sonnet`, `opus`, or `fable`). Without the flag, the reviewer model is sized per issue (see Model Sizing).

Regardless of flags, maintain a **processed set** of issue numbers handled this run (whatever the outcome). Never queue or process a number already in it. This prevents re-picking an issue left open in pr-only mode (issues only auto-close on merge) and, together with the depth cap, is the runaway guard for follow-up mode.

## Model Sizing

Every agent launch names its model explicitly:

- **Planner** — no `model` parameter: its definition pins Opus.
- **Implementer** — from the planner's `COMPLEXITY`: `trivial` or `standard` → `sonnet`; `complex` → `opus`. If an implementer's build turn fails outright on quality grounds (not environment problems) and the issue is retried, relaunch a fresh implementer one tier up (`sonnet` → `opus` → `fable`) — at most one retry per issue. If the user explicitly requests a model for the agents, that overrides the sizing.
- **Reviewer** — `--review-model` if given; otherwise `sonnet` when `COMPLEXITY` is `trivial`, else `opus`.
- **Verifier** — `sonnet`.

## Setup

1. Determine the GitHub username for assigning issues back:

   ```
   gh api user -q .login
   ```

2. Note the repo's default branch (`gh repo view --json defaultBranchName -q .defaultBranchName`) — the reviewer needs it.

3. **Pre-acquire app-driving grants (conditional).** If this project has a user-facing app (a GUI, web UI, or TUI — not a pure library) **and** the session has screen-control tools (computer use or browser automation), acquire every grant those tools need **now**, before processing begins: only the main session can mint grants — subagents can use them but cannot create them, and a run in progress cannot come back to ask. If either condition is false, skip this and note that end-to-end verification is off for the run.

   For a desktop app driven by computer control, **build it first.** Computer
   use resolves an app by finding its bundle on disk, so a project whose app
   has never been built has nothing to resolve and the request comes back
   saying the app is not installed — indistinguishable from a permissions
   refusal, and unfixable once processing is under way. Build from the current
   checkout, then request the grant; if that first request still reports the
   app as not installed, request once more after a short pause, since a
   freshly built bundle takes a moment to become resolvable. Browser
   automation needs no build — its grants are per-site.

## Issue Selection

**If the input is one or more issue numbers** (e.g., `42`, `451-455`, `12 14 17`), the work queue is those numbers, ascending. Process them one at a time through the workflow below; in `--follow-up` mode, also append each completed pipeline's `DEFERRED_ISSUES` to the queue (skipping the processed set). Stop when the queue is empty.

**If the input is a selection query** (e.g., `select all issues whose label begins with 'review-debt'`), operate in a loop:

1. Fetch the list of matching open issues, sorted by issue number ascending (oldest first).
   Use `gh issue list` with appropriate flags (`--label`, `--search`, `--state open`, `--json number,title,labels,body`, `--jq`, etc.).
2. **Skip processed issues.** Drop any issue already in the processed set (e.g., handled in pr-only mode and still open awaiting merge).
3. **Check dependencies.** For each issue (oldest first), inspect the issue body and comments for dependency references ("blocked by #N", "depends on #N", linked issues). If the blocking issue is still open, skip it for now and move to the next eligible issue.
4. Pick the first eligible (oldest, unblocked) issue.
5. Process it through the workflow below.
6. After the issue is handled, **re-fetch matching open issues from scratch** (not from a cached list — new issues may have been filed, previously blocked issues may now be unblocked). Repeat from step 2.
7. Continue until no eligible matching open issues remain.

In `--follow-up` mode, deferred issues reported by completed pipelines join the queue **even if they don't match the selection query** — being spawned by this run is what qualifies them.

## Per-Issue Workflow

Launch every agent in the foreground — pass `run_in_background: false` explicitly (agents default to background). **Do not use `isolation: "worktree"`** — the pipeline works in the main repo tree and creates its branch in-place.

### Step 1: Plan (issues:issue-planner)

Launch the planner with the issue number and GitHub username. It returns a `VERDICT` block. Spot-check its claims before acting on them (e.g., a cited "already fixed" commit actually exists, a "removed" file is actually gone). Then:

- **`research`** — the planner already posted findings and assigned the issue to the user. Record the outcome and move to the next issue.
- **`already-fixed`** — post a comment with the planner's reasoning and close:
  ```
  gh issue comment <NUMBER> --body "This issue has already been addressed. <reasoning>"
  gh issue close <NUMBER> --reason completed
  ```
  Record as `closed-completed`; next issue.
- **`stale`** or **`not-worth-fixing`** — post a comment and close:
  ```
  gh issue comment <NUMBER> --body "Closing as <not applicable | not worth fixing>. <reasoning>"
  gh issue close <NUMBER> --reason "not planned"
  ```
  Record as `closed-not-planned`; next issue.
- **`fix`** — keep `PLAN`, `DEVIATIONS`, `COMPLEXITY`, `SUGGESTED_REVIEW_LEVEL`, and `USER_FACING`; proceed.

### Step 2: Implement (issues:issue-implementer)

Launch the implementer with the model from Model Sizing and this input:

```
Fix GitHub issue #<NUMBER> — build turn.
GitHub username for assigning issues: <GITHUB_USERNAME>
Plan:
<the planner's PLAN section>
Deviations already known:
<the planner's DEVIATIONS section>
```

- **`STATUS: blocked`** — log the reason, record the outcome, move to the next issue.
- **`STATUS: pr-created`** — note `PR_NUMBER` and any `DEFERRED_ISSUES`; proceed. The agent is now paused on the PR branch awaiting its finalize message — do not leave the pipeline mid-issue.

### Step 3: Review (issues:issue-reviewer)

Launch the reviewer with the model from Model Sizing and this input:

```
Review PR #<PR_NUMBER>, which fixes issue #<NUMBER>.
Review level: <--review-level if given, else the planner's SUGGESTED_REVIEW_LEVEL>
Default branch: <DEFAULT_BRANCH>
```

- **`STATUS: review-complete`** — collect `CONFIRMED_FINDINGS` and `DEFERRED_ISSUES`; proceed.
- **`STATUS: blocked`** (code-review skill unavailable) — the PR exists but is unreviewed. Skip Steps 4–5, send the implementer a finalize message with **pr-only** mode and no findings (never merge an unreviewed PR, even with `--merge`), record the issue as `blocked` with the reviewer's reason, and move on.

### Step 4: Verify End-to-End (issues:issue-verifier — conditional)

Launch the verifier only if **all** of: the planner said `USER_FACING: yes`, Setup acquired (or found it needs no) app-driving grants, and the fix is not already covered by an equivalent end-to-end test the implementer ran.

Launch it with this input:

```
Verify issue #<NUMBER> / PR #<PR_NUMBER> end-to-end.
APP: <the app under test>. Granted apps: <every app Setup acquired a grant for> — every app not listed is off limits.
TARGET: <the specific VM, document, or fixture to drive — the one that is safe to wreck>
BEHAVIOR: <the planner's USER_FACING line, verbatim>
```

You fill in `APP` and `TARGET`: the verifier does not choose which app to drive or which fixture to wreck. `BEHAVIOR` is copied from the plan unedited — the verifier writes its own test script from it, and you do not write steps yourself.

- **`STATUS: verified`** — proceed.
- **`STATUS: failed`** — its `FAILURES` join the confirmed findings for Step 5.
- **`STATUS: skipped`** — note the reason for the summary; proceed.

Skipping this step when its conditions aren't met is the normal path, not a failure.

### Step 5: Finalize (SendMessage to the implementer)

Send the implementer (by the agent ID/name from Step 2) one finalize message:

```
Finalize issue #<NUMBER> / PR #<PR_NUMBER> — mode: <"merge" if --merge, else "pr-only">.
Confirmed review findings to apply:
<the reviewer's CONFIRMED_FINDINGS, plus any verifier FAILURES — or "none">
```

It applies the findings, re-tests, pushes, then merges (merge mode) or leaves the PR open and returns to the default branch (pr-only). Its terminal `STATUS: merged | pr-created | blocked` is the issue's outcome.

### Step 6: Handle Stalls

If any agent in the pipeline ends without its terminal `STATUS:` line — typically saying it is "waiting" for CI or a background task — the agent is done: notifications from tasks it orphaned may never be delivered. Do **not** end your turn to wait for one. Recover actively, in this order:

1. Check ground truth yourself: `gh pr view <PR> --json state,headRefOid,mergeStateStatus,statusCheckRollup` and `gh issue view <N> --json state`.
2. If everything left is mechanical — waiting for CI, merging, cleanup — finish it yourself with **blocking foreground** calls, to the same bar the implementer holds: merge per project conventions only on a verified green, and only in `--merge` mode.
3. Only if substantive work remains (unfixed findings, failing checks needing code changes), resume that agent once via SendMessage with explicit instructions to finish synchronously and return a terminal `STATUS:`. If it returns non-terminal a second time, take over per step 2 or record the issue as `blocked` — do not resume it again.

The same applies if a SendMessage result says the message was queued but the recipient never responds: re-send once, then take over.

### Step 7: Record, Compact, and Loop

Union the `DEFERRED_ISSUES` from every agent in the pipeline. In `--follow-up` mode, append numbers not already in the processed set to the work queue at the current issue's depth + 1 (unless that exceeds the depth cap); otherwise note them for the summary.

Before looping to the next issue, run `/compact` to free up context window space:

```
/compact Retain: (1) the full orchestrator instructions from /issues:fix; (2) the original input including any flags: "$ARGUMENTS"; (3) the list of issues processed so far and their outcomes; (4) the remaining work queue, including any follow-up issues appended from DEFERRED_ISSUES and each queued issue's depth; (5) the GitHub username and default branch; (6) which app-driving grants were acquired in Setup. Drop per-file diffs, build output, review details, and agent transcripts from completed issues.
```

Then go back to Issue Selection and re-fetch matching issues.

## Summary Report

After all issues are processed (or no eligible issues remain), report a summary:

```
## Fix-Issue Summary

| Issue | Status | PR | Notes |
|-------|--------|----|-------|
| #12   | merged | #45 | Fixed feed parsing bug (sonnet; verified end-to-end) |
| #14   | pr-created | #46 | PR open, awaiting your merge |
| #15   | closed | —  | Already fixed in recent commit |
| #17   | closed | — | Stale — code it referenced was removed |
| #18   | blocked | — | Needs clarification on expected behavior |
| #20   | research | — | Planner posted analysis and assigned to user |
| #23   | merged | #48 | Follow-up from #12's review (queued via --follow-up) |
```

Mark follow-up issues as such in the notes. Without `--follow-up`, list any reported `DEFERRED_ISSUES` below the table as unprocessed follow-ups the user may want to run next.

## Important Notes

- Process issues **one at a time**, serially. Do not run two pipelines in parallel — they share the repo tree.
- **Never end your turn while work is pending.** A run ends only by printing the Summary Report — with the queue empty and every pipeline terminal. Ending a turn to "wait for a notification" is how runs silently die: if you are ever tempted to write "waiting for…", switch to a blocking foreground wait or take the remaining steps over yourself (see Step 6).
- Always re-fetch issues between iterations — the list may have changed.
- Respect issue dependencies. Do not process an issue that is blocked by another open issue.
- The planner closing an issue as stale or not worth fixing is a valid, successful outcome — do not re-open or retry it.
- With `--merge`, merges do not need user confirmation: the plugin ships a PreToolUse hook that auto-approves `gh pr merge` for the `issues:issue-implementer` agent, so runs proceed unattended in accept-edits mode. Without `--merge`, no agent attempts a merge.
- In pr-only mode, each implementer branches from the default branch, so open PRs from earlier in the run are not included in later fixes. PRs that touch the same code may conflict at merge time — that is expected and resolved when the user merges.
- If a fix requires changes that are too large or risky, the implementer will comment and assign back. Do not override this.
