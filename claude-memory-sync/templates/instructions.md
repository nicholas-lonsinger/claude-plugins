<!-- Managed by the claude-memory-sync plugin — DO NOT EDIT. This file is
     re-rendered from the plugin's template (templates/instructions.md) on
     every sync run, so edits here are lost; the machine-local data-dir
     paths below are baked in at stamp time. Sections below map one-to-one
     onto plugin features so they can be composed independently if features
     become toggleable. -->

# Synced user-scope context (claude-memory-sync)

The two imports below load instructions and a memory index that sync across
machines via the claude-memory-sync plugin. The `user/` directory next to
this file is a symlink into the sync store, so anything written there syncs
automatically. Individual memories are NOT imported — read them on demand by
following the index.

@{{DATA}}/user/CLAUDE.md
@{{DATA}}/user/MEMORY.md

## Where to save new guidance or memories

Pick the destination by who the fact is for and where it applies:

| The fact is for… | Save it in… |
|---|---|
| This machine only (hostnames, local paths, hardware quirks) | `~/.claude/CLAUDE.md` directly — never synced |
| Me, every project — must always be in context | `{{DATA}}/user/CLAUDE.md` — keep it ruthlessly small |
| Me, every project — recall on demand | a new `{{DATA}}/user/<kebab-slug>.md` plus one index line in `{{DATA}}/user/MEMORY.md` |
| Me, this project only | per-project auto-memory — the default for project-specific facts, unchanged |
| Everyone who works in this repo | the repo's own `CLAUDE.md`, as a normal commit there |

Between the two "every project" rows, default to an indexed memory. Reserve
the always-load file for guidance that applies to virtually every session or
whose misses are costly; a rule that fires only in specific situations and is
tolerable to miss occasionally belongs in the index — even when it must fire
proactively (nothing at apply time will prompt a lookup). "Proactive" is not
a reason to always-load; it's a reason to write the index hook line so the
trigger situation is recognizable.

## Global memories (user scope)

Global memory files use the same format as per-project auto-memory files
(frontmatter with `name`/`description`/`metadata.type`, one fact per file)
and live adjacent to their index, `{{DATA}}/user/MEMORY.md` — one
`- [Title](file.md) — hook` line per memory. Growth belongs in indexed
memories, not the always-load file. Synced files are committed and pushed
automatically at session boundaries — never run git in the store yourself.
