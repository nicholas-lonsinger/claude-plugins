# nicholas-lonsinger-plugins

A collection of Claude Code plugins for developer productivity.

## Installation

Add this marketplace to Claude Code:

```
/plugin marketplace add nicholas-lonsinger/claude-plugins
```

Then install individual plugins:

```
/plugin install issues@nicholas-lonsinger-plugins
```

## Available Plugins

### statusline

Self-configuring status line for Claude Code. **No command to run — enabling the plugin
is the entire install.** A session-start hook writes the `statusLine` entry into
`~/.claude/settings.json` (only if you don't already have one) and keeps the render script
symlinked to the current plugin version, so updates apply automatically. Disable the plugin
to turn it off.

**Features:**

- Model name and output style
- Git branch with worktree detection, dirty/untracked flags, and ahead/behind tracking
- Context window usage percentage with input/output token counts
- Rate limit monitoring for 5-hour and 7-day windows with pace-based color coding

**Requirements:** `jq`, `git`, macOS or Linux

### claude-memory-sync

Cross-machine sync for Claude Code's memory and user-scope instructions,
backed by a **private** GitHub store repo (working copy at a path chosen at
install time, default `~/.claude-memory-sync`). Two kinds of content sync:

- **Per-project memory** (`~/.claude/projects/<slug>/memory/`): each
  project's memory directory becomes a symlink into the store's
  `memory/<name>/`, keyed by git origin identity — projects link up
  automatically as they're visited, with no per-project setup.
- **User-scope instructions and memories** (`<store>/user/`): an
  always-loaded global `CLAUDE.md` plus lazily-loaded indexed memories,
  imported into every session through an `@`-reference chain from
  `~/.claude/CLAUDE.md`.

Session hooks keep everything synced automatically: pull on session start,
push on session end, with concurrent edits to memory markdown reconciled by
an AI semantic merge driver (union-of-knowledge, three-way). `~/.claude`
itself stays free of git state. One user-level install covers every project
on the machine.

**Skills:**

| Skill | Command | Description |
|-------|---------|-------------|
| install | `/claude-memory-sync:install` | Set up this machine: create or clone the private store repo, link per-project memory, and enable user-scope sync |
| uninstall | `/claude-memory-sync:uninstall` | Disable sync on this machine and restore the stock layout — memory copied back, user-scope files kept working locally |

Until install runs, the bundled hooks no-op silently and a session-start
notice offers the install skill; the same channel later surfaces anything
needing attention (broken store, missing import line, memory conflicts).

**Requirements:** `git`, `gh` (authenticated), macOS or Linux

## Adding Plugins

Each plugin lives in its own subdirectory with a `.claude-plugin/plugin.json` manifest. See the `issues/` directory for an example of the expected structure.

## License

MIT
