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

Self-configuring status line for Claude Code, plus a matching row for each subagent in the
agent panel. **No command to run — enabling the plugin is the entire install.** A
session-start hook writes the `statusLine` and `subagentStatusLine` entries into
`~/.claude/settings.json` (each only if you don't already have one) and keeps the render
scripts symlinked to the current plugin version, so updates apply automatically. Disable
the plugin to turn it off.

**Status line:**

- Model name with the current reasoning effort level (e.g. `Opus 5 (xhigh)`), reflecting live `/effort` changes
- Git branch with worktree detection, dirty/untracked flags, and ahead/behind tracking
- Open pull request for the branch with review state (approved / changes requested / pending / draft)
- Context window usage percentage — color-coded yellow→red as the window fills — with input/output token counts
- Session code churn (lines added/removed)
- Rate limit monitoring for 5-hour and 7-day windows with pace-based color coding

**Subagent rows** replace the default `name · description · token count` with the same
visual grammar, in columns that line up across rows:

```
🤖 Opus 5      | 💭 92% / 1M   | ⏱ 3m14s  | 📋 Review the bridged networking diff | 🌿 eager-badger | Grepping the binary
🤖 Haiku 4.5   | 💭 75% / 200K | ⏱ 1h15m  | 📋 Summarize findings
🤖 Sonnet 5    | 💭 6% / 200K  | ✗ failed | 📋 Apply the fix batch                | Building
```

- Each agent's own model and reasoning effort, and its own context window — which differs per model, so the percentage is measured against the right denominator
- Elapsed time while running; a green check or red cross once finished
- The agent's worktree, shown only when it is working somewhere other than the session's directory
- Its live activity, which sits last so a narrow terminal truncates that rather than a column
- Column widths are measured from the rows actually on screen each tick, by display width, so emoji and colored figures still line up

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

### gittools

The two steps of the pull request lifecycle that are easy to get wrong —
knowing when CI is really green, and moving the local default branch after
the merge:

| Skill | Command | Description |
|-------|---------|-------------|
| wait-ci | `/gittools:wait-ci` | Block until a PR's CI is verifiably green on the commit you pushed; returns one verdict |
| freshen-main | `/gittools:freshen-main` | Fast-forward the local default branch after a merge, from any checkout or worktree |

`scripts/wait-for-ci.sh` pins the expected head SHA, confirms the push landed
via `git ls-remote`, waits for the required checks to register, watches, then
verifies the final rollup directly — where a bare `gh pr checks --watch` races
a fresh push and reports success on zero checks and on cancelled runs. The
skill runs in its own Sonnet subagent (`agents/skill-runner.md`) in the
background, so the caller receives one notification carrying the verdict and
none of the progress.

`scripts/freshen-main.sh` fetches with prune, resolves the default branch from
the remote's HEAD symref, finds whichever worktree has it checked out, and
fast-forwards there — the one vetted route from a worktree session, where the
branch is checked out in another directory and ad-hoc `git -C` is refused by
the worktree-isolation guard. It always ends with one verdict line:
`fast-forwarded`, `current`, `diverged`, `dirty`, `not-checked-out`, or
`setup-error`.

**Requirements:** `gh` (authenticated), `git`, macOS or Linux

### issues

GitHub issue management: `/issues:add` files well-formed issues with codebase
context, and `/issues:fix` orchestrates end-to-end fixes — for each issue an
Opus planning subagent verifies it still applies and designs the fix, an
implementing agent builds, tests, opens a PR, and runs code review, then
merges (`--merge`) or leaves the PR open. `--follow-up` also queues issues
spawned during the run.

In `--merge` mode the implementer merges only on a verified-green CI verdict
for the commit it pushed.

**Requirements:** `gh` (authenticated), `git`

## Adding Plugins

Each plugin lives in its own subdirectory with a `.claude-plugin/plugin.json` manifest. See the `issues/` directory for an example of the expected structure.

## License

MIT
