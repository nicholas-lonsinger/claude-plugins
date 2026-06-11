---
name: uninstall
description: Disable memory sync on this machine and restore the stock folder layout — copy memory back to real per-project directories, keep user-scope files working locally, remove the local store, then disable (recommended) or uninstall the plugin
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, AskUserQuestion
---

# Memory Sync Uninstall

You are disabling memory sync on this machine and putting the folder
structure back the way stock Claude Code expects it: every
`~/.claude/projects/<slug>/memory` that is currently a symlink into the
store's `memory/<name>/` becomes a real directory again with the same
contents, and the user-scope files keep working from a plain local copy
(`@` imports are a Claude Code feature, not a plugin feature). **Never
delete memory content.** The GitHub repo is left untouched.

The store lives at `<store-dir>` — read it from the `state-dir` marker in
Step 1 (it defaults to `~/.claude-memory-sync`) and substitute it wherever
`<store-dir>` appears below.

Assess first (Step 1), then gather the user's two real decisions in **one**
AskUserQuestion call (Step 2) before changing anything. Everything else —
pushing pending changes, restoring the real memory folders, switching off the
sync hook — happens automatically once they confirm, so keep it out of the
decision itself. Turning sync back on later means re-running
`/claude-memory-sync:install` (after `claude plugin enable …` first, if the
plugin was disabled rather than uninstalled).

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

## Step 2: Confirm the plan

Ask the user their two decisions in a **single AskUserQuestion call with two
questions**. These are the only choices that matter; don't pad the options with
every downstream consequence, or the decision feels overwhelming.

1. **Local store** — Trash the local store (`<store-dir>`) or keep it?
   - *Trash it (recommended)* — move it to Trash; memory is safe (restored
     locally below and still on GitHub).
   - *Keep it* — leave the directory on disk untouched.
2. **Plugin** — Disable the plugin or uninstall it?
   - *Disable (recommended)* — stays installed but inactive; re-enable anytime
     with `claude plugin enable`.
   - *Uninstall* — removed entirely; reinstall from the marketplace to return.

Keep each option's description to one short line. In the message accompanying
the questions, briefly remind the user that the rest of the teardown runs
automatically — push any pending changes, restore the real memory folders,
clear the install markers — and that they can pick **Other** on either question
to type a custom plan (e.g. skip the push, abort entirely) instead of the
listed options. Recommend **Trash it** and **Disable**.

Carry both answers forward: Q1 drives Step 7, Q2 drives Step 8.

## Step 3: Push pending changes

```bash
git -C "$STORE" status --short
"${CLAUDE_PLUGIN_ROOT}/scripts/claude-sync.sh" push
git -C "$STORE" log --oneline origin/main..HEAD   # should be empty
```

If unpushed commits remain (offline, push rejected), warn the user: local
restoration is still safe, but those commits won't reach other machines unless
pushed later or the store dir is kept. If the user chose **Trash it** in Step 2,
flag that trashing the store would discard those unpushed commits and
re-confirm before continuing.

## Step 4: Restore real memory directories

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

## Step 5: Restore user-scope files

If `~/.claude/CLAUDE.md` imports the instruction hub
(`grep -F "@$DATA/CLAUDE.md" ~/.claude/CLAUDE.md` matches):

1. Copy the store's user-scope dir to a plain local location:

   ```bash
   cp -a "$STORE/user" "$HOME/.claude/user"
   ```

2. In `~/.claude/CLAUDE.md`, replace the hub import line (and its
   `<!-- claude-memory-sync: … -->` marker comment) with direct imports, so
   the always-load file and the lazy memory index keep working without the
   plugin:

   ```
   @~/.claude/user/CLAUDE.md
   @~/.claude/user/MEMORY.md
   ```

   If the user prefers, offer instead to inline the (small) always-load
   content directly into `~/.claude/CLAUDE.md` and keep only the memory
   import.

3. Remove the hub: `rm -f "$DATA/CLAUDE.md"` — it references the store path
   and would go stale the moment the store is removed.

If the import line is absent (user-scope sync was never enabled on this
machine), skip this step.

## Step 6: Clear the install markers

```bash
rm -f "$DATA/state-repo" "$DATA/state-dir"
```

Removing the markers makes the sync hook no-op (`claude-sync.sh` exits early
without `state-repo`), so it can't act on the half-dismantled store while we
finish. The hooks are *fully* stopped in Step 8 by disabling or uninstalling
the plugin; the markers are cleared here so that if the user later re-enables
a disabled plugin, `install-check.sh` correctly nudges them to re-run
`/claude-memory-sync:install` rather than resuming against a deleted store.

## Step 7: Remove the store

If the user chose **Trash it** in Step 2, delete `<store-dir>` (prefer
`trash` over `rm -rf`). Everything in it was either pushed (Step 3) or copied
back (Steps 4–5). If they chose **Keep it**, skip this step and leave the
directory in place. Either way, mention that the GitHub repo still exists and
holds the synced history — deleting it (if wanted) is a manual step:
`gh repo delete <slug>`.

## Step 8: Disable or uninstall the plugin

This is the **last** action — it must run *after* Step 3's push and the store
removal, because uninstalling deletes the plugin cache those steps run from.
Run the command for the choice the user made in Step 2 (default: disable).

```bash
PLUGIN_ID="$(claude plugin list 2>/dev/null | grep -oE 'claude-memory-sync@[^[:space:]]+' | head -1)"
claude plugin disable   "$PLUGIN_ID" -s user        # Disable (recommended)
# — or —
claude plugin uninstall "$PLUGIN_ID" -s user -y     # Uninstall outright
```

The current session already loaded the plugin's `SessionEnd` hook, so it
lingers until the session restarts — harmless: the markers and store are gone,
so it no-ops (or, after uninstall, simply fails to exec and is ignored).

## Step 9: Report

Summarize: how many project directories were restored, whether user-scope
files were kept working locally, whether everything was pushed, what was
removed, and whether the plugin was **disabled** or **uninstalled**. If disabled, remind the user it can be reactivated with
`claude plugin enable claude-memory-sync@nicholas-lonsinger-plugins` followed
by `/claude-memory-sync:install`; if uninstalled, reinstalling from the
marketplace is the way back. Either way, tell them to restart open sessions
so the lingering hook clears.
