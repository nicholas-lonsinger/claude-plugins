---
name: uninstall
description: Disable memory sync on this machine and restore the stock folder layout — copy memory out of the store back to real per-project directories, remove the local store, then disable (recommended) or uninstall the plugin
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
machine. As the final step (Step 6) you'll either **disable** the plugin
(recommended — it stays installed but its hooks no longer run) or
**uninstall** it outright. Either way, turning sync back on later means
re-running `/claude-memory-sync:install` (after `claude plugin enable …`
first, if it was disabled).

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

## Step 4: Clear the install markers

```bash
rm -f "$DATA/state-repo" "$DATA/state-dir"
```

Removing the markers makes the sync hook no-op (`claude-sync.sh` exits early
without `state-repo`), so it can't act on the half-dismantled store while we
finish. The hooks are *fully* stopped in Step 6 by disabling or uninstalling
the plugin; the markers are cleared here so that if the user later re-enables
a disabled plugin, `install-check.sh` correctly nudges them to re-run
`/claude-memory-sync:install` rather than resuming against a deleted store.

## Step 5: Remove the store

With the user's confirmation, delete `<store-dir>` (prefer
`trash` over `rm -rf`). Everything in it was either pushed (Step 2) or
copied back (Step 3). Mention that the GitHub repo still exists and holds
the synced history — deleting it (if wanted) is a manual step:
`gh repo delete <slug>`.

## Step 6: Disable or uninstall the plugin

This is the **last** action — it must run *after* Step 2's push and the store
removal, because uninstalling deletes the plugin cache those steps run from.
Ask the user (AskUserQuestion) how to leave the plugin, **recommending
disable**:

- **Disable (recommended)** — keeps the plugin installed but inactive; its
  session hooks stop loading from the next session on. Reversible anytime
  with `claude plugin enable`.
- **Uninstall** — removes the plugin and its data dir entirely; coming back
  means reinstalling from the marketplace.

Resolve the plugin's id from the installed list, then run only the chosen
command:

```bash
PLUGIN_ID="$(claude plugin list 2>/dev/null | grep -oE 'claude-memory-sync@[^[:space:]]+' | head -1)"
claude plugin disable   "$PLUGIN_ID" -s user        # Disable (recommended)
# — or —
claude plugin uninstall "$PLUGIN_ID" -s user -y     # Uninstall outright
```

The current session already loaded the plugin's `SessionEnd` hook, so it
lingers until the session restarts — harmless: the markers and store are gone,
so it no-ops (or, after uninstall, simply fails to exec and is ignored).

## Step 7: Report

Summarize: how many project directories were restored, whether everything
was pushed, what was removed, and whether the plugin was **disabled** or
**uninstalled**. If disabled, remind the user it can be reactivated with
`claude plugin enable claude-memory-sync@nicholas-lonsinger-plugins` followed
by `/claude-memory-sync:install`; if uninstalled, reinstalling from the
marketplace is the way back. Either way, tell them to restart open sessions
so the lingering hook clears.
