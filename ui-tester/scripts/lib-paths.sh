#!/bin/bash
# Sourced by the ui-tester hooks: where the Tester keeps its run folders.
# Runs are bulky and disposable, so they live in the OS's cache folder rather
# than in ~/.claude, which holds the user's settings and history and is often
# backed up or synced. A cache folder isn't cleared on reboot, so a recheck
# days later still finds its run.

# Prints the run folders' parent: ~/Library/Caches/claude-tester/runs on
# macOS, $XDG_CACHE_HOME/claude-tester/runs elsewhere ($XDG_CACHE_HOME must be
# an absolute path, so a relative one falls back to ~/.cache).
tester_runs_dir() {
  case "$(uname -s)" in
    Darwin) printf '%s\n' "$HOME/Library/Caches/claude-tester/runs" ;;
    *)
      case "${XDG_CACHE_HOME:-}" in
        /*) printf '%s\n' "$XDG_CACHE_HOME/claude-tester/runs" ;;
        *) printf '%s\n' "$HOME/.cache/claude-tester/runs" ;;
      esac
      ;;
  esac
}
