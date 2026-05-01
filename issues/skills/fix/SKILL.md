---
name: fix
description: Fix GitHub issues by number or query. Pass an issue number, or instructions like "select all issues whose label begins with 'review-debt'"
argument-hint: "<issue-number or selection instructions>"
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

You are an orchestrator that coordinates issue-fixing agents. You select issues, launch an `issue-fixer` agent for each one, run PR reviews between phases, and manage the serial workflow.

## Input

$ARGUMENTS

## Agent Model

By default, launch **both** the `issue-fixer-phase1` and `issue-fixer-phase2` agents with `model: "sonnet"`. If the user explicitly requests a different model (e.g., "use opus for the agents"), use that model instead. This keeps the orchestrator on whatever model it was invoked with while the worker agents default to Sonnet for cost efficiency.

## Setup

Determine the GitHub username for assigning issues back:

```
gh api user -q .login
```

## Issue Selection

**If the input is a single issue number** (e.g., `42`), process that one issue and stop.

**If the input is a selection query** (e.g., `select all issues whose label begins with 'review-debt'`), operate in a loop:

1. Fetch the list of matching open issues, sorted by issue number ascending (oldest first).
   Use `gh issue list` with appropriate flags (`--label`, `--search`, `--state open`, `--json number,title,labels,body`, `--jq`, etc.).
2. **Check dependencies.** For each issue (oldest first), inspect the issue body and comments for dependency references ("blocked by #N", "depends on #N", linked issues). If the blocking issue is still open, skip it for now and move to the next eligible issue.
3. Pick the first eligible (oldest, unblocked) issue.
4. Process it through the workflow below.
5. After the issue is resolved, **re-fetch matching open issues from scratch** (not from a cached list — new issues may have been filed, previously blocked issues may now be unblocked). Repeat from step 2.
6. Continue until no eligible matching open issues remain.

## Per-Issue Workflow

### Step 1: Launch the Phase 1 Agent

Launch the `issue-fixer-phase1` agent in the foreground with `model: "sonnet"` (or the user-specified model) and the issue number and GitHub username. **Do not use `isolation: "worktree"`** — the agent works in the main repo tree, creates a branch in-place, and Phase 2 continues on that same branch without needing to check it out again.

```
Fix GitHub issue #<NUMBER>.
GitHub username for assigning issues: <GITHUB_USERNAME>
```

Wait for the agent to complete.

### Step 2: Handle Phase 1 Result

Based on the agent's return status:

- **`closed-completed`** or **`closed-not-planned`** — Issue was already resolved or not applicable. Skip to next issue.
- **`research`** — Issue was research-only. Agent posted findings and assigned to user. Skip to next issue.
- **`blocked`** — Agent could not complete the fix. Log the reason. Skip to next issue.
- **`pr-created`** — A PR was created. Proceed to Step 3.

### Step 3: Run PR Review

Run the full PR review toolkit on the created PR:

```
/review
```

Collect the review findings (critical issues, important issues, suggestions).

### Step 4: Launch the Phase 2 Agent with Review Findings

Launch an `issue-fixer-phase2` agent in the foreground with `model: "sonnet"` (or the user-specified model). **Do not use `isolation: "worktree"`** — the branch already exists in the main repo tree from Phase 1.

Include in the prompt:
- The issue number and GitHub username
- PR number, branch name, and the Phase 1 summary of what the PR does
- The full review findings

Wait for the agent to complete Phase 2.

### Step 5: Handle Phase 2 Result

- **`merged`** — PR was successfully merged. Record success.
- **`blocked`** — Agent could not complete. Log the reason.

### Step 6: Compact and Loop (if processing multiple issues)

Before looping to the next issue, run `/compact` to free up context window space:

```
/compact Retain: (1) the full orchestrator instructions from /issues:fix; (2) the original selection query: "$ARGUMENTS"; (3) the list of issues processed so far and their outcomes; (4) the GitHub username. Drop per-file diffs, build output, review details, and agent transcripts from completed issues.
```

Then go back to Issue Selection and re-fetch matching issues.

## Summary Report

After all issues are processed (or no eligible issues remain), report a summary:

```
## Fix-Issue Summary

| Issue | Status | PR | Notes |
|-------|--------|----|-------|
| #12   | merged | #45 | Fixed feed parsing bug |
| #15   | closed | —  | Already fixed in recent commit |
| #18   | blocked | — | Needs clarification on expected behavior |
| #20   | research | — | Posted analysis and assigned to user |
```

## Important Notes

- Process issues **one at a time**, serially. Do not launch multiple agents in parallel.
- Always re-fetch issues between iterations — the list may have changed.
- Respect issue dependencies. Do not process an issue that is blocked by another open issue.
- If a fix requires changes that are too large or risky, the agent will comment and assign back. Do not override this.
