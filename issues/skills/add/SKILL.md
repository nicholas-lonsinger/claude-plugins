---
name: add
description: Create a well-researched GitHub issue with codebase context, dependency analysis, and structured formatting
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, Agent, AskUserQuestion, WebFetch
---

# Add GitHub Issue

You are helping the user create a well-researched GitHub issue. Follow every step below in order. Do not skip steps.

## Step 1: Get the issue description

Check whether the user provided a description when invoking this skill (as arguments after `/issues:add`).

- **If arguments were provided**: use them as the high-level issue description.
- **If no arguments were provided**: ask the user to describe the issue they want to create. Wait for their response before continuing.

Store this description — it drives all subsequent steps.

## Step 2: Investigate the codebase

Before drafting the issue, build context about the project's current state. Do all of the following:

1. **Read project guidelines** — read `CLAUDE.md` at the repo root and any other convention/contributing files (e.g., `CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/`). These may contain issue formatting rules you must follow.
2. **Explore relevant code** — use the Agent tool (subagent_type: Explore) to investigate the areas of the codebase most relevant to the issue description. Understand the current implementation, architecture, and any constraints. Keep the exploration focused — you are gathering context, not doing a full audit.
3. **Identify the repo** — run `gh repo view --json owner,name -q '.owner.login + "/" + .name'` to get the owner/repo for later API calls.

## Step 3: Fetch open GitHub issues

Download the open issues from the repository to understand the existing issue landscape:

```bash
gh issue list --state open --limit 100 --json number,title,labels,body
```

Analyze the results to identify:
- **Duplicates** — does an issue already exist that covers this request? If so, tell the user and ask how they want to proceed.
- **Dependencies** — are there open issues that this new issue depends on, or that depend on what this issue would change?
- **Related work** — are there issues covering adjacent areas that should be cross-referenced?

Keep note of any issue numbers you will reference in the new issue body.

## Step 4: Ask qualifying questions (round 1)

Based on what you learned from the codebase and existing issues, ask the user targeted qualifying questions to fill in gaps. Questions should help you understand:

- Scope and acceptance criteria
- Priority and urgency
- Any technical constraints or preferences
- Whether this is a feature, bug fix, research task, or something else
- Specific files, modules, or behaviors involved

Ask all round-1 questions in a single message. Wait for the user's response.

## Step 5: Follow-up questions (round 2 — optional)

If the user's answers in round 1 raised new questions or left ambiguity, ask **one** follow-up round of clarifying questions. Keep this round short and focused.

If round 1 answers were sufficiently clear, skip this step and move to Step 6.

## Step 6: Draft and present the issue

Compose the full GitHub issue following any formatting rules found in project guidelines (Step 2). If no project-specific template exists, use this default structure:

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

Present the full draft to the user and ask for their approval. If they request changes, apply them and re-present until approved.

## Step 7: Post the issue

Once the user approves, create the issue using `gh`:

```bash
gh issue create --title "<title>" --body "$(cat <<'EOF'
<approved issue body>
EOF
)"
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

- **If yes**: go back to Step 1 (retain codebase context from Step 2 — no need to re-explore unless the new issue covers a different area).
- **If no**: thank the user and end.
