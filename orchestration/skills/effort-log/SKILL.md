---
name: effort-log
description: Record a judged subagent launch — its task-table row, model, effort level, and whether it met its Done — in the cross-machine effort log, which steps the row's model and effort in the task table from that evidence. Use after judging the result of every subagent launch, and for the per-row tally.
---

# Effort log

`scripts/effort-log` in this plugin owns the log: one TSV per session in the sync store, the row keys it accepts (read from the task table in the user CLAUDE.md), and the thresholds that step a row. `--help` lists every flag.

## Record a launch

Log a launch once, at the gate that judges its Done and before any follow-up message reaches it: a follow-up grows the same transcript, so a later log counts the follow-up's work and waits as the launch's. Judge the result as it came back — one that needed a correction is not `met`, however good it is after the fix. The script refuses an agent already in the log, so a continued agent is logged once. A check the Tester session serves is not a launch — its effort is that session's, not a row's — and is not logged.

    "${CLAUDE_PLUGIN_ROOT}/scripts/effort-log" add --row <key> --level <level> --outcome <outcome> --model <id> (--agent <agentId> | --workflow <runId> --label <label>) [--role escalation] [--note <text>]

- `--model` — the exact id the subagent ran on (`claude-opus-5-5`, never an alias); the script refuses an id the transcript disagrees with.
- `--level` — the effort the run used.
- `--outcome`
  - `met` — met its Done as returned.
  - `missed` — fell short for a reason more effort could fix, whether the remedy was a correction to the same agent or a rerun a level up.
  - `brief` — fell short because the brief lacked what the work needed, including a check the run could have executed that would have caught the miss, such as a test through the caller a fix stopped short of. `--note` names what the brief lacked.
  - `inconclusive` — nothing shows whether it met its Done.
- `--role escalation` — the rerun a level up after a `missed`. It counts as evidence at the level it ran at without ending the row's run at its own setting.
- `--agent` — the `agentId` an Agent launch returned. A Workflow never shows main its agents' ids, so a Workflow `agent()` is named instead by the completion's Run ID and the `label` the script gave it — one label per agent you log, since the script refuses a label shared by several agents or one whose result was reused from an earlier run. The script records the run's requests, tool calls, tokens by kind, and model, tool, and idle seconds from its transcript — the only lasting copy, since transcripts stay on this machine. No verdict reads them: a row moves on Done alone.

## How a row moves

After each `add` the script judges the logged row and, when the verdict is a step, rewrites that row's Model and Effort cells in the task table and prints `STEP DOWN` or `STEP UP` with the reason. Name the move in the reply's last line.

- **Step down** — only for a row whose Oracle is `yes`. After a streak of clean runs at its setting, the row moves one rung down: effort first, then the next cheaper model at the same effort (opus → sonnet → haiku). Each miss at that lower setting on its model's current version doubles the streak the step needs; a new version starts it over.
- **Step up** — a miss soon after a step down returns the row to the setting it came from; otherwise repeated recent misses move it one rung up, effort first. Misses at opus high go to the refresh-ladder skill.
- **Hold** — everything else, and always for a row without an oracle: there a miss can go unseen, so a clean streak proves nothing.

Evidence counts across a model's versions, so a new version keeps each row's setting and streak. The log never moves a row onto or off Fable. `brief` and `inconclusive` outcomes never move a row.

## Tally

`effort-log tally` prints each row's setting, streak, recent misses and verdict, then the rows where `brief` misses cluster, with their notes. A flagged row's briefs keep lacking something: from the notes, propose to the user what that row's briefs should carry — its Task text in the table, or the brief guidance beside it.
