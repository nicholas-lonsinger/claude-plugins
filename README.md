# nicholas-lonsinger-plugins

A collection of Claude Code plugins for developer productivity.

## Installation

Add this marketplace to Claude Code:

```
/plugin marketplace add nicholas-lonsinger/claude-plugins
```

Then install individual plugins:

```
/plugin install setup@nicholas-lonsinger-plugins
```

## Available Plugins

### setup

Environment setup utilities for Claude Code.

**Skills:**

| Skill | Command | Description |
|-------|---------|-------------|
| statusline | `/setup:statusline` | Install a custom status line with git info, context window usage, and rate limit monitoring |
| user-defaults | `/setup:user-defaults` | Configure `~/.claude/settings.json` and `~/.claude/CLAUDE.md` with default user settings — plugins, marketplace, preferences, and coding guidelines |

#### Status Line Features

- Model name and output style
- Git branch with worktree detection, dirty/untracked flags, and ahead/behind tracking
- Context window usage percentage with input/output token counts
- Rate limit monitoring for 5-hour and 7-day windows with pace-based color coding

**Requirements:** `jq`, `git`, macOS or Linux

### claude-memory-sync

Cross-machine sync for Claude Code's per-project memory files
(`~/.claude/projects/<slug>/memory/`). The `~/.claude` directory becomes the
working copy of a **private** GitHub state repo with a whitelist
`.gitignore` (memory files only — transcripts, settings, and caches stay
local). Session hooks keep it synced automatically: pull on session start,
push on session end, with concurrent edits to memory markdown reconciled by
an AI semantic merge driver (union-of-knowledge, three-way). One user-level
install covers every project on the machine.

**Skills:**

| Skill | Command | Description |
|-------|---------|-------------|
| install | `/claude-memory-sync:install` | Set up this machine: attach `~/.claude` to a private state repo (creating it if needed) and verify the sync round-trip |

Until install runs, the bundled hooks no-op silently and a session-start
notice offers the install skill.

**Requirements:** `git`, `gh` (authenticated), macOS or Linux

## Adding Plugins

Each plugin lives in its own subdirectory with a `.claude-plugin/plugin.json` manifest. See the `setup/` directory for an example of the expected structure.

## License

MIT
