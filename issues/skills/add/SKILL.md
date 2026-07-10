---
name: add
description: Create a well-researched GitHub issue with codebase context, dependency analysis, and structured formatting
argument-hint: "<issue description — a phrase is enough; omit to be prompted>"
disable-model-invocation: true
allowed-tools:
  - Read
  - Edit
  - Write
  - Bash
  - Glob
  - Grep
  - Task
  - AskUserQuestion
  - WebFetch
---

# Add GitHub Issue

You are helping the user create a well-researched GitHub issue. Follow every step below in order. Do not skip steps.

## Step 1: Get the issue description

Check whether the user provided a description when invoking this skill (as arguments after `/issues:add`).

- **If arguments were provided**: use them as the high-level issue description.
- **If no arguments were provided**: ask the user to describe the issue they want to create. Wait for their response before continuing.

Store this description — it drives all subsequent steps.

## Step 2: Assess the ask — minimal or detailed?

Decide which mode you are in. The test: after reading the description, could you write an issue where a competent implementer would know **what** to change, roughly **where**, and what **done** looks like?

- **Detailed ask** — the description names a concrete problem or behavior with enough scope to act on. Do NOT interrogate the user before drafting. Research (Steps 3–4), then go straight to the draft (Step 6), bundling any genuinely blocking questions alongside it.
- **Minimal ask** — a phrase, a hunch, an unshaped idea ("we should do something about the config sprawl"). The user is asking you to help **shape the ask**, not just transcribe it. Research first (Steps 3–4) so your questions are informed, then run the shaping round (Step 5) before drafting.

When in doubt, treat it as minimal — the user would rather be asked a good question than receive a confidently wrong issue.

## Step 3: Investigate the codebase

Before drafting the issue, build context about the project's current state. Do all of the following:

1. **Read project guidelines** — read `CLAUDE.md` at the repo root and any other convention/contributing files (e.g., `CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/`). These may contain issue formatting rules you must follow.
2. **Explore relevant code** — use the Task tool (subagent_type: Explore) to investigate the areas of the codebase most relevant to the issue description. Understand the current implementation, architecture, and any constraints. Keep the exploration focused — you are gathering context, not doing a full audit.
3. **Identify the repo** — run `gh repo view --json owner,name -q '.owner.login + "/" + .name'` to get the owner/repo for later API calls.

## Step 4: Scan open GitHub issues

Fetch the open issues **without bodies** — titles and labels are enough for a first pass:

```bash
gh issue list --state open --limit 200 --json number,title,labels
```

Scan the titles for:
- **Duplicate candidates** — issues that might already cover this request
- **Dependency candidates** — issues this new issue might depend on, or that depend on what it would change
- **Related work** — issues covering adjacent areas worth cross-referencing

Only for the handful of candidates you identified, fetch the full body to confirm:

```bash
gh issue view <number> --json number,title,body,labels
```

If a genuine duplicate exists, tell the user and ask how they want to proceed. Keep note of any issue numbers you will reference in the new issue body.

## Step 5: Shape the ask (minimal asks only)

Skip this step entirely for detailed asks.

For minimal asks, help the user turn the idea into a well-formed request. Ask targeted questions **informed by what you found in Steps 3–4** — never generic ones. Aim to pin down:

- Scope and acceptance criteria
- Priority and urgency
- Whether this is a feature, bug fix, research task, or something else
- Specific files, modules, or behaviors involved
- Any technical constraints or preferences

Use AskUserQuestion when the realistic answers are enumerable (you can offer concrete options grounded in the code); ask free-form otherwise. Ask everything in a single round. If the answers raise new ambiguity, ask **one** short follow-up round — no more.

## Step 6: Draft and present the issue

Compose the full GitHub issue following any formatting rules found in project guidelines (Step 3). If no project-specific template exists, use this default structure:

```markdown
## Summary

< concise description of the issue >

## Context

< relevant background: current behavior, codebase state, motivation >

## Requirements

< bulleted list of what "done" looks like >

## Dependencies

< list any related or blocking issues, e.g. "Depends on #42" or "Related to #15" — omit section if none >

## Additional Notes

< technical notes, constraints, design considerations — omit section if none >
```

Present the full draft to the user and ask for their approval. For detailed asks, this is also where any blocking questions go — present them **with** the draft ("here's the issue; I assumed X, flag if wrong") rather than as a gate before it. If the user requests changes, apply them and re-present until approved.

## Step 7: Post the issue

Once the user approves, write the body to a temporary file with the Write tool (avoids heredoc escaping issues), then create the issue:

```bash
gh issue create --title "<title>" --body-file <temp-file-path>
rm <temp-file-path>
```

**Research issues**: if the issue is a research task (the user indicated it, or the nature of the work is investigative — exploring options, evaluating approaches, producing recommendations rather than code changes), add the `research` label:

```bash
gh issue edit <number> --add-label "research"
```

If the `research` label does not exist in the repo, create it first:

```bash
gh label create "research" --description "Research task — investigate and recommend" --color "0E8A16"
```

After posting, display the issue URL to the user.

## Step 8: Loop

Ask the user if they would like to create another issue.

- **If yes**: go back to Step 1 (retain codebase context from Step 3 — no need to re-explore unless the new issue covers a different area).
- **If no**: thank the user and end.
