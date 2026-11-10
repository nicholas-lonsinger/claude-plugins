---
name: effort-log
description: Record a judged subagent launch — its task-table row, effort level, and whether it met its Done — in the cross-machine effort log, and report when the evidence moves a row's level. Use after judging the result of every subagent launch, and for the per-row tally that calibration reads.
---

# Effort log

`scripts/effort-log` in this plugin owns the log: one TSV per session in the sync store, the row keys it accepts (read from the task table in the user CLAUDE.md), and the thresholds that move a level. `--help` lists every flag.

## Record a launch

Log a launch once, at the gate that judges its Done and before any follow-up message reaches it: a follow-up grows the same transcript, so a later log counts the follow-up's work and waits as the launch's. The script refuses an agent already in the log. A check the Tester session serves is not a launch — its effort is that session's, not a row's — and is not logged.

    "${CLAUDE_PLUGIN_ROOT}/scripts/effort-log" add --row <key> --level <level> --outcome <outcome> --model <id> (--agent <agentId> | --workflow <runId> --label <label>) [--role <role> --pair <id>]

- `--model` — the exact id the subagent ran on (`claude-opus-5-5`, never an alias); the evidence counts per model, and the script refuses an id the transcript disagrees with.
- `--outcome`
  - `met` — met its Done. A pair's lower run is `met` only if it also missed nothing the brief needed that the upper caught.
  - `missed` — fell short for a reason more effort could fix.
  - `brief` — fell short because the brief lacked what the work needed, including a check the run could have executed that would have caught the miss, such as a test through the caller a fix stopped short of. It never moves a level; recurring `brief` misses on one row say what that row's briefs should carry.
  - `inconclusive` — nothing tells the runs apart, such as two reviews agreeing on finding nothing.
- `--role` — `single` by default; `upper` and `lower` for a pair's runs, with a shared `--pair` id; `escalation` for the rerun a level up after a miss.
- `--agent` — the `agentId` an Agent launch returned. A Workflow never shows main its agents' ids, so a Workflow `agent()` is named instead by the completion's Run ID and the `label` the script gave it — one label per agent you log, since the script refuses a label shared by several agents or one whose result was reused from an earlier run. The script records the run's requests, tool calls, tokens by kind, and model, tool, and idle seconds from its transcript — the only lasting copy, since transcripts stay on this machine. No verdict reads them: a row's level moves on Done alone.

Output starting `LEVEL CHANGE` names a row whose Effort cell in the table should change; the log repeats it until the table agrees.

## Tally

`effort-log tally` prints each row's evidence at its current level for the current model, with a verdict: `raise`, `drop`, `probe` (too few pair comparisons against the level below), or `hold`.
