---
name: calibrate
description: Turn on effort calibration for the rest of this session — run launches of under-tested task-table rows as pairs against the level below, judge each pair, and let the effort log move the table's levels. Pass `off` to end it.
argument-hint: "[off]"
disable-model-invocation: true
---

# Calibrate

$ARGUMENTS

With `off`, calibration ends and launches run alone again. Otherwise the rules below hold for the rest of this session, on top of the orchestration rules in CLAUDE.md.

## What to pair

Start from the effort log's tally. A launch of a row the tally marks `probe` runs as a pair; every other launch runs alone. A run that uses a shared VM also runs alone, whatever its row.

## Running a pair

The same brief at the row's level and at the level below, in parallel.

- Pair only work that can be thrown away. Each edit run gets its own `isolation: "worktree"`, each brief names its own scratch subdirectory, and a step that acts outside the session — a push, a PR, a comment, a deletion, a review's `--comment`, `--fix`, or `--post` — runs once, after the pair, on the result taken.
- Wait for both, never stopping one early: a comparison with one side cut short is no evidence.
- Take the better result; a review pair acts on the union of both findings. Follow-up work goes by `SendMessage` to the run whose result was taken, and the other run's worktree is discarded.

## Judging a pair

Judge each run against the brief's Done, with the effort log's outcomes. The miss a lower level typically makes is a fix that stops at one layer — the edited code and its own tests pass while a second caller still breaks — so the judge checks every caller and consumer of what changed, not the brief's named site alone. Where an oracle decides — the suite, CI, one review run over both branches — its verdict stands. Where none does, launch a judge at the `adversarial` row's level with the brief and both results, labeled only A and B in random order, and take its verdict: this session knows which run was which. The judge runs alone and is not logged.

Record both runs with a shared pair id, then end the reply with one line: the row, both outcomes, and any level change the log reported.

## Improving the method

When a pair shows a better way to classify, brief, judge, or pair — a row whose wording misled, a judging mistake, a step that wasted a run — propose the rewrite of the orchestration section of CLAUDE.md, this skill, or the effort log in the reply, and make it only when the user agrees.
