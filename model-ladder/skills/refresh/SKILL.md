---
name: refresh
description: Re-derive the model and effort each row of the subagent task table runs on — from task-specific benchmark scores and cost per task at every effort level, Anthropic's model guidance, and the effort log — and propose the table changes for approval. Use when a new Claude model or version ships, Anthropic publishes new model-choice guidance, or a plan's usage limits change.
argument-hint: "[what changed, e.g. a new model]"
disable-model-invocation: true
---

# Refresh the model ladder

$ARGUMENTS

Run this in the main session: subagents gather the evidence, this session decides, and the user approves. Nothing in the task table or the ladder memory changes before that approval.

## Inputs

- **The task table** in the user CLAUDE.md's orchestration section — each row's current model and effort.
- **The ladder memory** (`subagent-effort-ladder`) — the bar a row must clear to leave the default model, and any usage cap behind it. A new limit or bar the user states during this run is written there.
- **The effort log's tally** — per row misses and brief misses on the row's model. Recurring brief misses say the row's briefs need work, which no model change fixes.
- **Anthropic's current model guidance** — its which-model guide on claude.dev, the models overview on platform.claude.com, and each current model's launch post and system card. Its task-to-model table is the starting assumption for each row.

## Phases

**1. Scope.** Name the current version of each model family and what changed since the table was last set. Sort the rows by kind of work:

| Kind of work | What measures it |
|---|---|
| Agentic coding against a spec or a test suite | Terminal-Bench, FrontierCode, CursorBench, SWE-bench Pro |
| Review and debugging | code-review benchmarks (such as Qodo's), SWE-bench Pro |
| Locating code and answering questions about a codebase | codebase question answering (such as SWE-Atlas-QnA) |
| Reading long documents and logs | long-context reading (such as AA-LCR) |
| Reasoning, planning, design, research | HLE, Terminal-Bench Science, CritPt, factual accuracy (such as AA-Omniscience) |
| Computer use and vision | OSWorld, SWE-bench Multimodal |
| Writing | report-writing benchmarks (such as AA-Briefcase) |
| Multi-step tool runs | automation benchmarks (such as AutomationBench) |

Benchmark versions turn over; the kinds of work don't. Where the guidance or the benchmarks separate two kinds of work that one row merges, propose splitting the row only if the two halves would land on different models or levels.

**2. Research.** Launch a subagent on the task table's `research` row. Brief it to collect, for each kind of work, the score and the cost (or tokens) per task at every effort level of every current model:
- vendor and independent numbers kept apart, and second-hand quotes marked;
- every number taken from a page it fetched, with the URL;
- numbers seen only in search summaries listed as unconfirmed;
- earlier model versions in a separate list;
- no recommendations.

Sources worth pointing it at:
- **Artificial Analysis's per-effort model pages**, `artificialanalysis.ai/models/claude-<model>-<low|medium|high|xhigh>` (no suffix is max). Each page embeds every benchmark's score, output tokens and cost per task as JSON in the page source, not in the visible text. Each page also embeds other models' records for comparison, so the first record on a page is not necessarily that page's model. Attribute each record to the model name it sits under.
- **The system cards' evaluation sections**, which publish effort sweeps.
- **Benchmark owners' own leaderboards and reports**, such as Cursor, Qodo, Vals and Zapier.

*Gate:* re-fetch the numbers that decide each proposed change and confirm them against their pages before using any.

**3. Blend.** For each row:
- Judge it on its kind of work's benchmarks. Use a general-intelligence index only where no task-specific benchmark exists, and say so.
- Keep Anthropic's recommendation unless the task-specific data disagrees with it, and name the benchmarks that do.
- Apply the ladder memory's rules for leaving the default model.
- Check the escalation rung: the next effort level on the row's model should gain on that kind of work. Flag a row whose data shows no gain from that level.
- Note what the numbers leave out: run labels such as "Default Fallback" (refused requests rerun on another model), pricing the benchmark doesn't model (a long-prompt price tier, for example), and how few runs each number rests on.

**4. Propose.** *Gate:* show the user one table, with the columns Row | Current | Anthropic | What the task-specific data shows | Proposed start → after a miss. Then list:
- what changes;
- where the data overturned Anthropic's guidance;
- any splits worth making;
- the caveats.

Wait for the user's approval.

**5. Apply.** Edit the Model and Effort cells in the task table, the one place they live. Change the ladder memory only if a rule changed. Run the effort log's tally to confirm the table still parses. A row whose model moves to a new version shows nothing logged until its first judged launch: its evidence starts fresh.
