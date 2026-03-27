---
name: kernova
description: Configure Claude Code for Kernova development — user settings, project local settings, Xcode MCP, and swift-lsp
allowed-tools: Read, Edit, Write, Bash, Glob, Grep
---

# Kernova Development Setup

You are configuring Claude Code for Kernova development on this machine. Follow each phase in order, confirming with the user before writing changes.

## Phase 1: User-Level Settings

Read `~/.claude/settings.json` (create with `{}` if it doesn't exist). Merge the following keys — do not remove or overwrite any existing keys:

```json
"enabledPlugins": {
  "setup@nicholas-lonsinger-plugins": true,
  "pr-review-toolkit@claude-plugins-official": true
}
```

```json
"extraKnownMarketplaces": {
  "nicholas-lonsinger-plugins": {
    "source": {
      "source": "github",
      "repo": "nicholas-lonsinger/claude-plugins"
    }
  }
}
```

```json
"effortLevel": "high"
```

```json
"skipDangerousModePermissionPrompt": true
```

**Important:**
- If `enabledPlugins` already exists, add the new entries without removing existing ones.
- If `extraKnownMarketplaces` already exists, merge the new entry.
- Do NOT add `statusLine` or `hooks` — those are handled by `/setup:statusline`.
- Present the proposed changes to the user and confirm before writing.
- Read back `~/.claude/settings.json` after writing to verify.

## Phase 2: Xcode Toolchain

Run `xcode-select -p` and check the output:

- **If it returns `/Applications/Xcode.app/Contents/Developer`** — proceed to Phase 3.
- **If it returns anything else** (e.g., `/Library/Developer/CommandLineTools`) — tell the user they need to switch to Xcode by running:
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
  Ask the user to run this command (it requires sudo). Do not proceed to Phase 3 until `xcode-select -p` returns the correct path.

## Phase 3: Xcode MCP Server

Run `claude mcp list` and check if an `xcode` entry already exists.

- **If it exists** — skip this step.
- **If it does not exist** — run:
  ```bash
  claude mcp add --transport stdio xcode -- xcrun mcpbridge
  ```
  Then run `claude mcp list` again to verify it was added.

## Phase 4: Kernova Project Settings

### Step 1: Locate the project

Check if `~/Developer/GitHub/nicholas-lonsinger/Kernova` exists. If not, ask the user for the Kernova repo path.

### Step 2: settings.local.json

Read `{kernova}/.claude/settings.local.json` if it exists. Merge the following JSON into it (create the file if absent):

```json
{
  "enabledPlugins": {
    "swift-lsp@claude-plugins-official": true
  },
  "permissions": {
    "allow": [
      "WebFetch(domain:api.github.com)",
      "WebFetch(domain:github.com)"
    ],
    "additionalDirectories": [
      "/Volumes/My Shared Files/Kernova"
    ]
  },
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true,
    "enableWeakerNetworkIsolation": true,
    "filesystem": {
      "allowWrite": [
        "/Volumes/My Shared Files/Kernova/"
      ]
    }
  }
}
```

**Merge rules:**
- `enabledPlugins`: add entries, don't remove existing ones
- `permissions.allow`: append new entries, don't duplicate existing ones
- `permissions.additionalDirectories`: append, don't duplicate
- `sandbox.filesystem.allowWrite`: append, don't duplicate
- All other keys: set if absent, preserve if already present

### Step 3: CLAUDE.local.md

Check if `{kernova}/CLAUDE.local.md` already exists.

- **If it does not exist** — copy the template from `${CLAUDE_PLUGIN_ROOT}/scripts/templates/kernova-CLAUDE.local.md` to `{kernova}/CLAUDE.local.md`.
- **If it already exists** — show the user a comparison between the existing file and the template. Ask whether to overwrite or skip.

## Phase 5: Verification & Report

1. Read back all modified files and confirm they are correct:
   - `~/.claude/settings.json`
   - `{kernova}/.claude/settings.local.json`
   - `{kernova}/CLAUDE.local.md`

2. Tell the user what was configured:
   - User-level: which plugins, marketplace, effort level
   - Xcode: toolchain status, MCP server status
   - Kernova: swift-lsp, permissions, sandbox, CLAUDE.local.md

3. Remind the user to run `/setup:statusline` if they also want the custom status line.
