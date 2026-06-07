---
name: install
description: Set up cross-machine memory sync on this machine — create or clone the private store repo at ~/.claude-memory-sync and verify the sync round-trip
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, AskUserQuestion
---

# Memory Sync Install

You are setting up this machine to sync Claude Code's per-project memory
files to a private GitHub repo. The store repo lives at
**`~/.claude-memory-sync`** and holds one directory per project under
`memory/<name>/`, keyed by git origin identity (a `.origin` breadcrumb in
each). Per machine, the plugin's session hooks automatically symlink
`~/.claude/projects/<slug>/memory` into the store — projects link up (or
get adopted into the store) as they're visited, so this single user-level
install covers every project on the machine, current and future, with no
per-project setup. `~/.claude` itself stays free of git state.

The plugin's session hooks are already active (they came with plugin
enablement) but no-op silently until this install completes.

Every step is idempotent — running this skill on a fully or partially
installed machine is safe; skip any step whose check passes.

## How it works (context)

- Session hooks drive syncing: SessionStart pulls (async) and maintains the
  project's symlink; SessionEnd adopts/links and pushes. Concurrent-edit
  conflicts in memory markdown are resolved by an AI merge driver
  (union-of-knowledge, three-way).
- Plugin state (install marker, sync log, lock) lives in the plugin data
  dir: `${CLAUDE_PLUGIN_DATA}` (falls back to
  `~/.claude/plugins/data/claude-memory-sync-nicholas-lonsinger-plugins`).
  The marker file `state-repo` holds the chosen `owner/name` slug; the sync
  scripts refuse to touch any repo that doesn't match it.

## Step 0: Preconditions

Check, and stop with a clear message if any fails:

```bash
command -v git && gh auth status
```

`gh` must be authenticated — the state repo is private.

## Step 1: Assess current state

```bash
DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claude-memory-sync-nicholas-lonsinger-plugins}"
cat "$DATA/state-repo" 2>/dev/null                              # already installed?
git -C ~/.claude-memory-sync remote get-url origin 2>/dev/null  # store repo present?
```

If the marker exists AND the store repo's origin matches it: report "already
installed", run only Step 6 (verify), and stop.

If `~/.claude/.git` exists, mention it to the user: pre-0.2.0 versions of
this plugin made `~/.claude` itself the state repo, and a leftover `.git`
there should be removed (with their confirmation) so Claude's state dir
stays clean — the old whitelist plumbing files (`~/.claude/.gitignore`,
`~/.claude/.gitattributes`, `~/.claude/README.md`) go with it. Prefer
`trash` over `rm`.

## Step 2: Choose the state repo

Ask the user (AskUserQuestion) for the GitHub repo to sync memory to.
Suggest `<gh-username>/claude-memory-sync` as the default (get the username from
`gh api user -q .login`). Accept a bare name as shorthand for
`<gh-username>/<name>`. Tell the user plainly: the repo holds private
memory contents and will be created **private** / must already be private.

## Step 3: Create or clone the store repo

`~/.claude-memory-sync` must not already exist as something else — if it
does and isn't a clone of the chosen repo, stop and ask the user.

Check repo existence: `gh repo view <slug>`.

**Repo does not exist — create:**

```bash
gh repo create <slug> --private
mkdir ~/.claude-memory-sync && cd ~/.claude-memory-sync
git init -b main
cp "${CLAUDE_PLUGIN_ROOT}/templates/gitignore"     .gitignore
cp "${CLAUDE_PLUGIN_ROOT}/templates/gitattributes" .gitattributes
cp "${CLAUDE_PLUGIN_ROOT}/templates/README.md"     README.md
mkdir -p memory
git add -A && git commit -m "init: memory sync from $(hostname -s)"
git remote add origin "https://github.com/<slug>.git"
git push -u origin main
```

**Repo exists — clone:**

1. Verify privacy: `gh repo view <slug> --json isPrivate -q .isPrivate`
   must be `true`. If public, warn hard and require explicit confirmation
   to continue (memory contents are private).
2. `git clone "https://github.com/<slug>.git" ~/.claude-memory-sync`
3. If the clone contains a top-level `projects/` tree, it has the pre-0.2.0
   whitelist layout — stop and recommend deleting/recreating the repo (or
   choosing another); this skill does not restructure old layouts.
4. Lay down any missing templates (`.gitignore`, `.gitattributes`,
   `README.md`, `memory/`) as above and commit if anything changed.

## Step 4: Register the merge driver

```bash
cd ~/.claude-memory-sync
git config merge.claude-ai.name "Claude semantic three-way merge"
git config merge.claude-ai.driver "${CLAUDE_PLUGIN_ROOT}/scripts/claude-merge.sh %O %A %B %P"
```

(The sync script re-stamps this on every run; setting it here just covers
the very first sync.)

## Step 5: Write the install marker

```bash
printf '%s\n' "<slug>" > "$DATA/state-repo"
rm -f "$DATA/uninstalled"
```

This arms the session hooks: from now on `claude-sync.sh` syncs on session
start/end, and `install-check.sh` goes silent. (The `uninstalled` sentinel,
if present from a previous /claude-memory-sync:uninstall, must be cleared.)

## Step 6: Link the current project and verify

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/claude-sync.sh" pull
git -C ~/.claude-memory-sync config merge.claude-ai.driver  # → current plugin cache path
git -C ~/.claude-memory-sync status --short --branch        # clean, tracking origin/main
ls -la ~/.claude/projects/ | head                           # current project's memory → symlink?
tail -5 "$DATA/sync.log"
```

The `pull` also runs the link/adopt step for the current project: if it has
real memory, it's adopted into `memory/<name>/` and replaced with a symlink
(verify with `ls -la`). Other projects adopt lazily at their next session.
If this session's project had its memory adopted just now, push it:
`"${CLAUDE_PLUGIN_ROOT}/scripts/claude-sync.sh" push`.

## Step 7: Report

Summarize what was done vs. already in place (repo created/cloned,
templates, marker, driver, current project linked). Remind the user:
restart any open sessions so the session-start pull engages, and on the
next machine the flow is just install plugin → `/claude-memory-sync:install`
→ name the same repo.
