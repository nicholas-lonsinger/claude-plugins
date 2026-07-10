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

You are an orchestrator that coordinates issue-fixing agents. You select issues, launch an `issues:issue-fixer` agent for each one, and manage the serial workflow. Each agent handles its issue end-to-end: an Opus planning subagent verifies the issue still applies and designs the fix, then the agent implements it, creates a PR, runs `/code-review medium --fix`, and merges.

## Input

$ARGUMENTS

## Agent Model

By default, launch the `issues:issue-fixer` agent with `model: "sonnet"` and no effort override (it inherits the session's effort level). If the user explicitly requests a different model (e.g., "use opus for the agents"), use that model instead. This keeps the orchestrator on whatever model it was invoked with while the implementing agent defaults to Sonnet for cost efficiency.

Internally, the agent pins its planning subagent to Opus — planning and issue-verification judgment get the stronger model while implementation stays on Sonnet. A user model override changes the implementing agent, not the planner.

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

### Step 1: Launch the Issue-Fixer Agent

Launch the `issues:issue-fixer` agent in the foreground with `model: "sonnet"` (or the user-specified model) and the issue number and GitHub username. **Do not use `isolation: "worktree"`** — the agent works in the main repo tree and creates its branch in-place.

```
Fix GitHub issue #<NUMBER>.
GitHub username for assigning issues: <GITHUB_USERNAME>
```

Wait for the agent to complete. The agent has its Opus planner verify the issue still applies and design the fix, implements it, creates a PR, runs `/code-review medium --fix`, addresses PR comments, and merges.

### Step 2: Handle the Result

Based on the agent's return status:

- **`closed-completed`** or **`closed-not-planned`** — Issue was already resolved, stale, or judged not worth fixing. The agent posted its reasoning on the issue. Record the outcome and move to the next issue.
- **`research`** — Issue was research-only. Agent posted findings and assigned to user. Move to the next issue.
- **`blocked`** — Agent could not complete the fix. Log the reason. Move to the next issue.
- **`merged`** — PR was created, reviewed, and merged. Record success.

### Step 3: Compact and Loop (if processing multiple issues)

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
| #17   | closed | — | Stale — code it referenced was removed |
| #18   | blocked | — | Needs clarification on expected behavior |
| #20   | research | — | Posted analysis and assigned to user |
```

## Important Notes

- Process issues **one at a time**, serially. Do not launch multiple agents in parallel.
- Always re-fetch issues between iterations — the list may have changed.
- Respect issue dependencies. Do not process an issue that is blocked by another open issue.
- An agent closing an issue as stale or not worth fixing is a valid, successful outcome — do not re-open or retry it.
- If a fix requires changes that are too large or risky, the agent will comment and assign back. Do not override this.
