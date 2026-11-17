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
- `--level` — the effort the run used. A run at a setting other than the row's current one, such as one launched before a move reached this session, counts at the setting it ran at.
- `--outcome`
  - `met` — met its Done as returned.
  - `missed` — fell short for a reason more effort could fix, whether the remedy was a correction to the same agent or a rerun a level up.
  - `brief` — fell short because the brief lacked what the work needed, including a check the run could have executed that would have caught the miss, such as a test through the caller a fix stopped short of. `--note` names what the brief lacked.
  - `inconclusive` — nothing shows whether it met its Done.
- `--role escalation` — the rerun a level up after a `missed`; it counts at the level it ran at.
- `--agent` — the `agentId` an Agent launch returned. A Workflow never shows main its agents' ids, so a Workflow `agent()` is named instead by the completion's Run ID and the `label` the script gave it — one label per agent you log, since the script refuses a label shared by several agents or one whose result was reused from an earlier run. The script records the run's requests, tool calls, tokens by kind, and model, tool, and idle seconds from its transcript — the only lasting copy, since transcripts stay on this machine. No verdict reads them: a row moves on Done alone.

## Set a row by judgment

    "${CLAUDE_PLUGIN_ROOT}/scripts/effort-log" baseline --row <key> --model <haiku|sonnet|opus|fable> --level <low|medium|high> --note <who and why>

A baseline sets the setting a row's computation starts from, and from then on only runs logged after it count as the row's evidence. A new row needs one before its runs count; refresh-ladder records one for each row it changes and for each row it wants re-probed on a new model version. `--carry` keeps the row's earlier runs as evidence too, and `--from-table` takes one baseline per row from the table's Model and Effort columns.

## How a row moves

Every run counts at the setting it ran at, whichever session or machine logged it and whenever its file synced. A row's setting is recomputed from that evidence on every read, starting at its baseline:

- **Step up** — while the setting's recent runs keep missing (the latest among them a miss), the row moves one rung up, effort first, then the next model (haiku → sonnet → opus). A row whose misses come at the top of its ladder (opus or Fable at high) holds for refresh-ladder.
- **Step down** — only for a row whose Oracle is `yes`. After a streak of clean runs, counted since the latest miss at its setting or any setting below it, the row moves one rung down: effort first, then the next cheaper model at the same effort. So one streak pays for one probe. A miss at a setting below the baseline sends the row back up, even after a long clean run there, and every miss at a setting, or at one dominating it, doubles the streak a step onto it needs.
- **Hold** — everything else. A row without an oracle never steps down: a miss there can go unseen, so a clean streak proves nothing.

The log never moves a row onto or off Fable. `brief` and `inconclusive` outcomes never move a row. Model versions pool: a new version is re-probed only when a baseline says so.

Because settings are recomputed rather than stored, a change to the script's thresholds or to a row's Oracle cell can move rows from the same evidence. Record baselines alongside such a change when rows should stay where they are.

## Tally

`effort-log tally` prints each row's baseline, setting, the path from one to the other, its streak and recent misses, then the rows where `brief` misses cluster, with their notes. A flagged row's briefs keep lacking something: from the notes, propose to the user what that row's briefs should carry — its Task text in the table, or the brief guidance beside it.
