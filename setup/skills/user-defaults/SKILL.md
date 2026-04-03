---
name: user-defaults
description: Configure ~/.claude/settings.json with default user settings — plugins, marketplace, and preferences
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, AskUserQuestion
---

# User Defaults Setup

You are configuring the user's `~/.claude/settings.json` with a standard set of defaults. This skill merges a known-good configuration template into the user's existing settings without removing anything they already have.

## Core Template

The following settings are always applied:

```json
{
  "enabledPlugins": {
    "setup@nicholas-lonsinger-plugins": true,
    "issues@nicholas-lonsinger-plugins": true,
    "pr-review-toolkit@claude-plugins-official": true
  },
  "extraKnownMarketplaces": {
    "nicholas-lonsinger-plugins": {
      "source": {
        "source": "github",
        "repo": "nicholas-lonsinger/claude-plugins"
      },
      "autoUpdate": true
    }
  },
  "effortLevel": "high",
  "skipDangerousModePermissionPrompt": true
}
```

## Optional Sandbox Template

The following sandbox settings are only applied if the user opts in:

```json
{
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true,
    "allowUnsandboxedCommands": false,
    "enableWeakerNetworkIsolation": true,
    "excludedCommands": ["xcodebuild*"]
  }
}
```

## Steps

### Step 1: Read current settings

Read `~/.claude/settings.json`. If the file does not exist, treat the current settings as `{}`.

### Step 2: Ask about sandbox settings

Ask the user whether they want to enable sandbox settings. Explain what the sandbox configuration does:

- **`enabled: true`** — turns on the command sandbox
- **`autoAllowBashIfSandboxed: true`** — automatically allows bash commands when the sandbox is active (no per-command prompts)
- **`allowUnsandboxedCommands: false`** — blocks commands that would bypass the sandbox
- **`enableWeakerNetworkIsolation: true`** — relaxes network restrictions (allows outbound network access)
- **`excludedCommands: ["xcodebuild*"]`** — exempts xcodebuild from sandboxing since it requires system access

If the user declines, proceed without the sandbox block. If they accept, include it in the merge.

### Step 3: Compute the merge

Merge the core template (and the sandbox template if accepted) into the existing settings using these rules:

- **`enabledPlugins`**: add new entries without removing existing ones
- **`extraKnownMarketplaces`**: merge the new entry; if `nicholas-lonsinger-plugins` already exists, update it to match the template
- **`sandbox`** (if accepted): set the entire `sandbox` object to the template value
- **All other keys** (`effortLevel`, `skipDangerousModePermissionPrompt`): set to the template value

Never remove existing keys or entries that are not part of the template.

### Step 4: Present and confirm

Show the user the proposed merged `settings.json` and ask for confirmation before writing.

### Step 5: Write and verify

Write the merged result to `~/.claude/settings.json`. Then read the file back and confirm all template keys are present and correct.

### Step 6: Report

Tell the user what was configured:
- Plugins enabled: setup, issues, pr-review-toolkit
- Nicholas Lonsinger marketplace registered with auto-update
- Effort level set to `high`, dangerous mode prompt skipped
- Sandbox: enabled (with details) **or** skipped per user preference
