# Claude Code memory backup

Cross-machine backup and sync of Claude Code's per-project memory files,
managed by the
[claude-memory-sync](https://github.com/nicholas-lonsinger/claude-plugins)
plugin. The working copy lives at `~/.claude-memory-sync`; one directory per
project under `memory/<name>/`, keyed by git origin identity (each carries a
`.origin` breadcrumb). Per machine, the plugin's session hooks automatically
symlink `~/.claude/projects/<slug>/memory` into this store — projects link up
as they're visited, with no per-project setup.

Do not edit this repo by hand; syncing is automatic via Claude Code session
hooks.

> **Privacy:** memory contents live here. This repo must stay **private**.

To set up a new machine: install the plugin, then run
`/claude-memory-sync:install` and point it at this repo.
