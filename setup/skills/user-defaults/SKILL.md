---
name: user-defaults
description: Configure ~/.claude/settings.json with default user settings — model, plugins, marketplace, and preferences
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, AskUserQuestion
---

# User Defaults Setup

You are configuring the user's `~/.claude/settings.json` with a standard set of defaults. This skill merges a known-good configuration template into the user's existing settings without removing anything they already have.

## Template

The following is the full default template:

```json
{
  "model": "OpusPlan",
  "enabledPlugins": {
    "setup@nicholas-lonsinger-plugins": true,
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
  "skipDangerousModePermissionPrompt": true,
  "outputStyle": "Explanatory"
}
```

## Steps

### Step 1: Read current settings

Read `~/.claude/settings.json`. If the file does not exist, treat the current settings as `{}`.

### Step 2: Compute the merge

Merge the template into the existing settings using these rules:

- **`enabledPlugins`**: add new entries without removing existing ones
- **`extraKnownMarketplaces`**: merge the new entry; if `nicholas-lonsinger-plugins` already exists, update it to match the template
- **All other keys** (`model`, `effortLevel`, `skipDangerousModePermissionPrompt`, `outputStyle`): set to the template value

Never remove existing keys or entries that are not part of the template.

### Step 3: Present and confirm

Show the user the proposed merged `settings.json` and ask for confirmation before writing.

### Step 4: Write and verify

Write the merged result to `~/.claude/settings.json`. Then read the file back and confirm all template keys are present and correct.

### Step 5: Report

Tell the user what was configured:
- Model set to `OpusPlan`
- Plugins enabled: setup, pr-review-toolkit
- Nicholas Lonsinger marketplace registered with auto-update
- Effort level set to `high`, dangerous mode prompt skipped, output style set to `Explanatory`
