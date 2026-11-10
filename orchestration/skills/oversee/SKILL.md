---
name: oversee
description: Oversee a GitHub issue or a described task end to end — plan, implement, review, verify, deliver — delegating each phase to a subagent while this session keeps every decision and the responsibility for the outcome. Pass an issue number or a task description; add --merge to merge on a clean review.
argument-hint: "<issue-number | task description> [--merge]"
disable-model-invocation: true
---

# Oversee

You run this in the main session. You delegate the work and keep the decisions. Nothing reaches the user as done until you have checked it.

## Input

$ARGUMENTS

## What you own, what they own

You own the gates below, spot-checking a subagent's claims, triaging review findings, deciding merge-readiness, and talking to the user. You do not implement, run build loops, or read whole diffs. Read only what a gate decision needs — a report, one cited file, one claimed commit.

Subagents own everything else.

## Phases and gates

**0. Intake.** Read the issue or task. Run the user `CLAUDE.md`'s from-scratch check; if it finds a structural gap, the plan phase plans the migration, unless the user makes a *for now* call on the change in place. Size it: a small mechanical change skips the plan phase and goes to implement with a brief you write yourself. If verification may need to drive the app, check `ListAgents` for this repository's Tester session, named as the `use-tester` skill says. If one is running, verification goes to it and nothing here touches the screen. If none is, acquire screen-control grants now — only this session can, and a subagent that finds it needs one has no way back.

**1. Plan.** The planner first verifies the issue still applies to the current tree, then produces a plan naming files, risks, whether the change is user-facing, and how it will be verified. *Gate:* you read the plan against the better-architecture rule in the repo's instructions. Accept it, amend it, or send it back with what is wrong. An issue that is already fixed or stale ends here with a comment and a close.

**2. Implement.** Brief: branch per project conventions, implement the accepted plan, build and tests green, commit. *Gate:* the report shows a green run of the project's test command. Spot-check one claim before proceeding — a named test exists, a cited file changed.

**3. Review** → fresh subagents, never the implementer. Tell them the branch, the default branch, and to flag only gaps that affect correctness or the stated requirements; a reviewer told to find gaps will report some regardless. Each reviewer is a launch of the task table's `review` row and runs the project's review skill at that row's level. *Gate:* triage every finding through the repo's review-handling categories. Findings to fix go back to the implementer by message, with the findings and nothing else. Findings deferred become issues.

**4. Verify** → only when the plan said user-facing and the fix is not already covered by an equivalent end-to-end test. With a Tester running, send it the implementer's committed SHA and a test plan in the request format the `use-tester` skill defines, and wait for its reply. Without one, a subagent drives the app and reports observed versus intended, after this session has acquired every grant it needs. *Gate:* a failed step goes back to the implementer by message with the observation, and the fix is verified again on its new commit. Skipping this phase when its conditions are unmet is the normal path.

**5. Deliver.** The implementer pushes, opens the PR per project conventions, and waits for CI to be verifiably green using the project's CI-wait skill. Merge only with `--merge` or when the user says so, and only on a verified green. Without `--merge`, leave the PR open and say so. Once the merge is confirmed, run in the same turn every post-merge step the project's instructions and skills call for — each is triggered by the merge itself, not by the user asking.

## Waiting

Agents run in the background and notify you when they stop. While the pipeline is blocked on one, end your turn; do not poll and do not take over its work. If an agent stops without a terminal report, check ground truth yourself (`gh pr view`, `git log` on its branch) before resuming it once with explicit instructions to finish and report.

## Report to the user

Outcome in one line, the PR link, what was verified and how, and what remains open — including any finding you dismissed and why.
