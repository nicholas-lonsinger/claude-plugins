---
name: uninstall
description: Disable memory sync on this machine and restore the stock folder layout — copy memory out of the store back to real per-project directories, then remove the local store repo
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, AskUserQuestion
---

# Memory Sync Uninstall

You are disabling memory sync on this machine and putting the folder
structure back the way stock Claude Code expects it: every
`~/.claude/projects/<slug>/memory` that is currently a symlink into the
store's `memory/<name>/` becomes a real directory again with the same
contents. **Never delete memory content.** The GitHub repo is left
untouched.

The store lives at `<store-dir>` — read it from the `state-dir` marker in
Step 1 (it defaults to `~/.claude-memory-sync`) and substitute it wherever
`<store-dir>` appears below.

Confirm with the user before doing anything — this stops syncing on this
machine until they reinstall.

## Step 1: Assess

```bash
DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claude-memory-sync-nicholas-lonsinger-plugins}"
cat "$DATA/state-repo" 2>/dev/null
STORE="$(cat "$DATA/state-dir" 2>/dev/null)"   # the chosen <store-dir>,
STORE="${STORE:-$HOME/.claude-memory-sync}"    #   default if the marker is absent
git -C "$STORE" remote get-url origin 2>/dev/null
```

If neither the marker nor the store at `<store-dir>` exists, report "not
installed" and stop.

## Step 2: Push pending changes

```bash
git -C "$STORE" status --short
"${CLAUDE_PLUGIN_ROOT}/scripts/claude-sync.sh" push
git -C "$STORE" log --oneline origin/main..HEAD   # should be empty
```

If unpushed commits remain (offline, push rejected), warn the user: continuing
is safe for local restoration, but those commits won't reach other machines
unless pushed later or the store dir is kept.

## Step 3: Restore real memory directories

For each symlink under `~/.claude/projects/*/memory` that points into
`<store-dir>/memory/`:

```bash
target="$(cd ~/.claude/projects/<slug>/memory && pwd -P)"   # resolve store dir
rm ~/.claude/projects/<slug>/memory                          # remove only the symlink
cp -a "$target" ~/.claude/projects/<slug>/memory             # copy contents back
rm -f ~/.claude/projects/<slug>/memory/.origin               # breadcrumb is store-internal
```

Verify each restored directory holds the same `*.md` files as its store
counterpart before moving on. Leave non-symlink memory directories alone.

## Step 4: Disarm the hooks

```bash
rm -f "$DATA/state-repo" "$DATA/state-dir"
touch "$DATA/uninstalled"
```

The marker removal stops syncing; the `uninstalled` sentinel keeps
`install-check.sh` from nudging about setup in every future session. A
later `/claude-memory-sync:install` clears the sentinel.

## Step 5: Remove the store

With the user's confirmation, delete `<store-dir>` (prefer
`trash` over `rm -rf`). Everything in it was either pushed (Step 2) or
copied back (Step 3). Mention that the GitHub repo still exists and holds
the synced history — deleting it (if wanted) is a manual step:
`gh repo delete <slug>`.

## Step 6: Report

Summarize: how many project directories were restored, whether everything
was pushed, what was removed. Remind the user the plugin itself is still
enabled (hooks are inert thanks to the sentinel) and can be fully removed
via `/plugins` if desired.
