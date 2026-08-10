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

- Model name with the current reasoning effort level (e.g. `Opus 4.8 (xhigh)`), reflecting live `/effort` changes
- Git branch with worktree detection, dirty/untracked flags, and ahead/behind tracking
- Open pull request for the branch with review state (approved / changes requested / pending / draft)
- Context window usage percentage — color-coded yellow→red as the window fills — with input/output token counts
- Session code churn (lines added/removed)
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

### github

Cleanup for the step of the pull request lifecycle that is easy to get wrong —
moving the local default branch after the merge:

| Skill | Command | Description |
|-------|---------|-------------|
| freshen-main | `/github:freshen-main` | Fast-forward the local default branch after a merge, from inside a worktree |

`scripts/freshen-main.sh` does the work. A squash merge advances the branch on
the remote and leaves the local ref behind, and a session running inside a git
worktree cannot move it: the branch is checked out in another directory, so no
in-worktree git command touches it, and ad-hoc `git -C <other-checkout>` is
refused by the worktree-isolation guard. The script fetches with prune,
resolves the default branch from the remote's HEAD symref, finds whichever
worktree has it checked out, and fast-forwards there — printing one line when
it moves the branch and staying silent when there is nothing safe to do.

**Requirements:** `gh` (authenticated), `git`, macOS or Linux

### issues

GitHub issue management: `/issues:add` files well-formed issues with codebase
context, and `/issues:fix` orchestrates end-to-end fixes — for each issue an
Opus planning subagent verifies it still applies and designs the fix, an
implementing agent builds, tests, opens a PR, and runs code review, then
merges (`--merge`) or leaves the PR open. `--follow-up` also queues issues
spawned during the run.

In `--merge` mode the fixer waits on `gh pr checks <PR> --watch --fail-fast`
and merges only when it exits 0.

**Requirements:** `gh` (authenticated), `git`

## Adding Plugins

Each plugin lives in its own subdirectory with a `.claude-plugin/plugin.json` manifest. See the `issues/` directory for an example of the expected structure.

## License

MIT
