<!-- Managed by the claude-memory-sync plugin — DO NOT EDIT. This file is
     re-rendered from the plugin's template (templates/instructions.md) on
     every sync run, so edits here are lost; the store paths below are baked
     in at stamp time. Sections below map one-to-one onto plugin features so
     they can be composed independently if features become toggleable. -->

# Synced user-scope context (claude-memory-sync)

The two imports below load instructions and a memory index that sync across
machines via the claude-memory-sync plugin. Individual memories are NOT
imported — read them on demand by following the index.

@{{STORE}}/user/CLAUDE.md
@{{STORE}}/user/MEMORY.md

## Where to save new guidance or memories

Pick the destination by who the fact is for and where it applies:

| The fact is for… | Save it in… |
|---|---|
| This machine only (hostnames, local paths, hardware quirks) | `~/.claude/CLAUDE.md` directly — never synced |
| Me, every project — must always be in context | `{{STORE}}/user/CLAUDE.md` — keep it ruthlessly small |
| Me, every project — recall on demand | a new `{{STORE}}/user/<kebab-slug>.md` plus one index line in `{{STORE}}/user/MEMORY.md` |
| Me, this project only | per-project auto-memory — the default for project-specific facts, unchanged |
| Everyone who works in this repo | the repo's own `CLAUDE.md`, as a normal commit there |

## Global memories (user scope)

Global memory files use the same format as per-project auto-memory files
(frontmatter with `name`/`description`/`metadata.type`, one fact per file)
and live adjacent to their index, `{{STORE}}/user/MEMORY.md` — one
`- [Title](file.md) — hook` line per memory. Growth belongs in indexed
memories, not the always-load file. Synced files are committed and pushed
automatically at session boundaries — never run git in the store yourself.
