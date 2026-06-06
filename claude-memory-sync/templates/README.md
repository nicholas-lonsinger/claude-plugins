# Claude Code memory backup

Cross-machine backup and sync of Claude Code's per-project memory files
(`projects/<slug>/memory/`), managed by the
[claude-memory-sync](https://github.com/nicholas-lonsinger/claude-plugins)
plugin. The `~/.claude` directory itself is the working copy of this repo —
do not clone it elsewhere or edit this repo by hand; syncing is automatic
via Claude Code session hooks.

> **Privacy:** memory contents live here. This repo must stay **private**.

To set up a new machine: install the plugin, then run
`/claude-memory-sync:install` and point it at this repo.
