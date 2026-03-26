---
name: statusline
description: Install a custom Claude Code status line with git info, context window, and rate limit monitoring
allowed-tools: Read, Edit, Write, Bash, Glob, Grep
---

# Status Line Setup

You are configuring the user's Claude Code status line. This skill installs a custom status line that displays:

- **Model & output style** (e.g., `Opus 4.6 | Explanatory`)
- **Git info** with branch, worktree detection, modified/untracked flags, and ahead/behind tracking
- **Context window** usage percentage with input/output token counts
- **Rate limits** for 5-hour and 7-day windows with pace-based color coding and countdown timers

## Installation Steps

Follow these steps exactly:

### Step 1: Copy the scripts

Copy the bundled scripts to `~/.claude/` and make them executable:

```bash
cp "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh" ~/.claude/statusline.sh
cp "${CLAUDE_PLUGIN_ROOT}/scripts/statusline-cleanup.sh" ~/.claude/statusline-cleanup.sh
chmod +x ~/.claude/statusline.sh ~/.claude/statusline-cleanup.sh
```

### Step 2: Configure settings.json

Read the user's `~/.claude/settings.json` file. Then apply these two changes:

1. **Add the `statusLine` key** (top-level):
```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/statusline.sh"
}
```

2. **Add a `SessionEnd` hook** to the `hooks` key (create `hooks` if it doesn't exist):
```json
"hooks": {
  "SessionEnd": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "~/.claude/statusline-cleanup.sh"
        }
      ]
    }
  ]
}
```

**Important:** If the user already has a `hooks` key with other hooks, merge the `SessionEnd` entry — do not overwrite existing hooks. If `SessionEnd` already exists with matching content, skip it.

### Step 3: Verify

After configuration, read back `~/.claude/settings.json` and confirm the `statusLine` and `hooks.SessionEnd` entries are present and correct.

### Step 4: Report

Tell the user:
- The status line is now configured and active
- The status line shows: model, output style, git branch with worktree/dirty/ahead-behind info, context window usage, and rate limits with pace-based coloring

## Requirements

- `jq` must be installed (used by the status line script to parse session JSON)
- `git` must be installed (for git info display)
- macOS or Linux (the script uses `stat` with macOS flags, with Linux fallback)
