---
name: effort-log
description: Record a judged subagent launch — its task-table row, model, effort level, and whether it met its Done — in the cross-machine effort log, whose evidence sets each row's model and effort. Use after judging the result of every subagent launch, to set a row's baseline, and for the per-row tally.
---

# Effort log

`scripts/effort-log` in this plugin owns the log: one TSV per session in the sync store, the row keys and Oracle values it reads from the task table in the user CLAUDE.md, and the thresholds that step a row. `--help` lists every flag.

Each row's current model and effort is computed from the whole log, merged across sessions and machines, and never stored anywhere else. A hook prints the settings at session start; `add` prints any move it causes.

## Record a launch

Log a launch once, at the gate that judges its Done and before any follow-up message reaches it: a follow-up grows the same transcript, so a later log counts the follow-up's work and waits as the launch's. Judge the result as it came back — one that needed a correction is not `met`, however good it is after the fix. The script refuses an agent already in the log, so a continued agent is logged once. A check the Tester session serves is not a launch — its effort is that session's, not a row's — and is not logged.

    "${CLAUDE_PLUGIN_ROOT}/scripts/effort-log" add --row <key> --level <level> --outcome <outcome> --model <id> (--agent <agentId> | --workflow <runId> --label <label>) [--role escalation] [--note <text>]

- `--model` — the exact id the subagent ran on (`claude-opus-5-5`, never an alias); the script refuses an id the transcript disagrees with.
- `--level` — the effort the run used. A run at a setting other than the row's current one, such as one launched before a move reached this session, is logged as evidence that doesn't move the row.
- `--outcome`
  - `met` — met its Done as returned.
  - `missed` — fell short for a reason more effort could fix, whether the remedy was a correction to the same agent or a rerun a level up.
  - `brief` — fell short because the brief lacked what the work needed, including a check the run could have executed that would have caught the miss, such as a test through the caller a fix stopped short of. `--note` names what the brief lacked.
  - `inconclusive` — nothing shows whether it met its Done.
- `--role escalation` — the rerun a level up after a `missed`; it never moves the row.
- `--agent` — the `agentId` an Agent launch returned. A Workflow never shows main its agents' ids, so a Workflow `agent()` is named instead by the completion's Run ID and the `label` the script gave it — one label per agent you log, since the script refuses a label shared by several agents or one whose result was reused from an earlier run. The script records the run's requests, tool calls, tokens by kind, and model, tool, and idle seconds from its transcript — the only lasting copy, since transcripts stay on this machine. No verdict reads them: a row moves on Done alone.

## Set a row by judgment

    "${CLAUDE_PLUGIN_ROOT}/scripts/effort-log" baseline --row <key> --model <haiku|sonnet|opus|fable> --level <low|medium|high> --note <who and why>

A baseline sets a row's setting outright and starts its run there fresh. A new row needs one before its runs count; refresh-ladder records one for each row it changes. `--carry` keeps the row's earlier unbroken run of results at that setting instead of starting fresh, and `--from-table` takes one baseline per row from the table's Model and Effort columns.

## How a row moves

- **Step down** — only for a row whose Oracle is `yes`. After a streak of clean runs at its setting, the row moves one rung down: effort first, then the next cheaper model at the same effort (opus → sonnet → haiku). A setting the row stepped up out of on the model's current version bounds every setting at or below it: each such failure doubles the streak a step there needs. Failures don't fade within a version, since each one is a probe of that same model; a new version clears them.
- **Step up** — a miss within the first few runs after a step down returns the row to the setting it came from. Repeated misses in its recent runs at its setting move any row one rung up, effort first. A row whose misses come at the top of its ladder (opus or Fable at high) holds for refresh-ladder.
- **Hold** — everything else. A row without an oracle never steps down: a miss there can go unseen, so a clean streak proves nothing.

Evidence counts across a model's versions, so a new version keeps each row's setting and streak. The log never moves a row onto or off Fable. `brief` and `inconclusive` outcomes never move a row.

## Tally

`effort-log tally` prints each row's setting, how it got there, its streak, recent misses and last action, then the rows where `brief` misses cluster, with their notes. A flagged row's briefs keep lacking something: from the notes, propose to the user what that row's briefs should carry — its Task text in the table, or the brief guidance beside it.
