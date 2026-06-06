---
name: install
description: Set up cross-machine memory sync on this machine — attach ~/.claude to a private GitHub state repo (creating it if needed) and verify the sync round-trip
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, AskUserQuestion
---

# Memory Sync Install

You are setting up this machine to sync Claude Code's per-project memory
files (`~/.claude/projects/<slug>/memory/`) to a private GitHub repo. The
plugin's session hooks are already active (they came with plugin
enablement) but no-op silently until this install completes. Memory lives
centrally under `~/.claude/projects/`, so this single user-level install
covers every project on the machine — current and future — with no
per-project setup.

Every step is idempotent — running this skill on a fully or partially
installed machine is safe; skip any step whose check passes.

## How it works (context)

- `~/.claude` itself becomes the working copy of the state repo (no
  symlinks, no second checkout). A whitelist `.gitignore` syncs **only**
  `projects/*/memory/**` plus repo plumbing; transcripts, settings, caches,
  and everything else stay local.
- Session hooks drive syncing: SessionStart pulls (async), SessionEnd
  pushes. Concurrent-edit conflicts in memory markdown are resolved by an
  AI merge driver (union-of-knowledge, three-way).
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
cat "$DATA/state-repo" 2>/dev/null                    # already installed?
git -C ~/.claude remote get-url origin 2>/dev/null    # already a git repo?
```

If the marker exists AND `~/.claude`'s origin matches it: report "already
installed", run only Step 6 (verify), and stop.

## Step 2: Choose the state repo

Ask the user (AskUserQuestion) for the GitHub repo to sync memory to.
Suggest `<gh-username>/claude-memory` as the default (get the username from
`gh api user -q .login`). Accept a bare name as shorthand for
`<gh-username>/<name>`. Tell the user plainly: the repo holds private
memory contents and will be created **private** / must already be private.

## Step 3: Handle a pre-existing ~/.claude git repo

If `~/.claude/.git` exists and its origin does NOT match the chosen slug,
stop and explain: `~/.claude` is already attached to a different repo, and
a directory can only have one `.git`. With the user's explicit confirmation,
archive it — never delete it:

```bash
mv ~/.claude/.git "$DATA/replaced-git-$(date +%Y%m%d-%H%M%S)"
```

If the user declines, abort the install.

## Step 4: Create or attach the repo

Check existence: `gh repo view <slug>`.

**Repo does not exist — create:**

```bash
gh repo create <slug> --private
cd ~/.claude
git init -b main
cp "${CLAUDE_PLUGIN_ROOT}/templates/gitignore"     .gitignore
cp "${CLAUDE_PLUGIN_ROOT}/templates/gitattributes" .gitattributes
cp "${CLAUDE_PLUGIN_ROOT}/templates/README.md"     README.md
git add -A && git commit -m "init: memory sync from $(hostname -s)"
git remote add origin "https://github.com/<slug>.git"
git push -u origin main
```

(If a root file already exists — e.g. a hand-written README — show the user
the diff against the template and ask before overwriting; `.gitignore` and
`.gitattributes` are load-bearing and must end up as the template versions.)

**Repo exists — attach and merge:**

1. Verify privacy: `gh repo view <slug> --json isPrivate -q .isPrivate`
   must be `true`. If public, warn hard and require explicit confirmation
   to continue (memory contents are private).
2. In `~/.claude`: `git init -b main` (if needed), lay down the templates
   as above, commit local memory files first, then:

```bash
git remote add origin "https://github.com/<slug>.git"
git fetch origin
git config merge.claude-ai.name "Claude semantic three-way merge"
git config merge.claude-ai.driver "${CLAUDE_PLUGIN_ROOT}/scripts/claude-merge.sh %O %A %B %P"
git merge --allow-unrelated-histories --no-edit origin/main
git push -u origin main
```

The driver registration must come *before* the merge so overlapping memory
files get the AI union-merge rather than raw conflicts
(`--allow-unrelated-histories` is needed only for this first join of the
two histories). If the merge still conflicts, stop and show the user the
conflicted paths rather than resolving destructively.

## Step 5: Write the install marker

```bash
printf '%s\n' "<slug>" > "$DATA/state-repo"
```

This arms the session hooks: from now on `claude-sync.sh` syncs on session
start/end, and `install-check.sh` goes silent.

## Step 6: Verify

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/claude-sync.sh" pull
git -C ~/.claude config merge.claude-ai.driver   # → current plugin cache path
git -C ~/.claude status --short --branch          # clean, tracking origin/main
tail -5 "$DATA/sync.log"
```

## Step 7: Report

Summarize what was done vs. already in place (repo created/attached,
templates, marker, driver). Remind the user: restart any open sessions so
the session-start pull engages, and on the next machine the flow is just
install plugin → `/claude-memory-sync:install` → name the same repo.
