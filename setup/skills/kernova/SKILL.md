---
name: kernova
description: Configure Claude Code for Kernova development — user settings, project local settings, and swift-lsp
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, AskUserQuestion
---

# Kernova Development Setup

You are configuring Claude Code for Kernova development on this machine. This skill is **interactive** — you audit the current state first, then present a menu of sections so the user can choose what to configure.

## User Overrides

The user may provide free-text instructions after the slash command (e.g., `/setup:kernova put the artifact directory at ~/Downloads/Kernova`). If they do, parse the instructions and apply them as overrides to the defaults below. Common overrides include:

- **Artifact directory** — any mention of changing the shared/artifact directory path should replace all occurrences of `/Volumes/My Shared Files/Kernova` in the project settings section (`additionalDirectories`, `sandbox.filesystem.allowWrite`) and in the CLAUDE.local.md template.
- **Project path** — any mention of a different repo location should replace the default `~/Developer/GitHub/nicholas-lonsinger/Kernova`.
- **Skip sections** — if the user says to skip a section, respect that.
- **Any other modifications** — apply them where they logically fit. If ambiguous, ask the user for clarification before proceeding.

If no overrides are provided, use all defaults as written below.

---

## Step 1: Audit Current State

Before presenting any options, silently run ALL of the following checks in parallel where possible. Do NOT show intermediate output — collect everything first, then present the summary.

### Checks to run:

1. **User settings** — Read `~/.claude/settings.json` (if it exists). Check whether each of these keys/values is already present:
   - `enabledPlugins["setup@nicholas-lonsinger-plugins"]` is `true`
   - `enabledPlugins["pr-review-toolkit@claude-plugins-official"]` is `true`
   - `extraKnownMarketplaces["nicholas-lonsinger-plugins"]` exists with the correct source and `autoUpdate` is `true`
   - `effortLevel` is `"high"`
   - `skipDangerousModePermissionPrompt` is `true`

2. **Xcode toolchain** — Run `xcode-select -p` and check if the output is `/Applications/Xcode.app/Contents/Developer`.

3. **Kernova project path** — Check if `~/Developer/GitHub/nicholas-lonsinger/Kernova` exists.

4. **Project local settings** — If the Kernova project path exists, read `{kernova}/.claude/settings.local.json` (if it exists) and check whether the expected keys are present:
   - `enabledPlugins["swift-lsp@claude-plugins-official"]` is `true`
   - `permissions.allow` contains `WebFetch(domain:api.github.com)` and `WebFetch(domain:github.com)`
   - `permissions.additionalDirectories` contains `/Volumes/My Shared Files/Kernova`
   - `sandbox.enabled` is `true`, `autoAllowBashIfSandboxed` is `true`, `enableWeakerNetworkIsolation` is `true`
   - `sandbox.filesystem.allowWrite` contains `/Volumes/My Shared Files/Kernova/`

5. **CLAUDE.local.md** — If the Kernova project path exists, check whether `{kernova}/CLAUDE.local.md` exists and if its content matches the template at `${CLAUDE_PLUGIN_ROOT}/scripts/templates/kernova-CLAUDE.local.md`.

### Present the Summary

After collecting all results, present a single formatted summary using this structure:

```
## Kernova Setup — Current State

| #  | Section                  | Status          |
|----|--------------------------|-----------------|
| 1  | User-level settings      | ✅ Configured / ⚠️ Partial (details) / ❌ Not configured |
| 2  | Xcode toolchain          | ✅ Correct / ❌ Wrong path: ... |
| 3  | Project local settings   | ✅ Configured / ⚠️ Partial (details) / ❌ Not configured / ⚠️ Project not found |
| 4  | CLAUDE.local.md          | ✅ Up to date / ⚠️ Differs from template / ❌ Missing / ⚠️ Project not found |
```

For items marked ⚠️ Partial, include a short parenthetical about what's missing (e.g., "missing effortLevel, marketplace").

Then ask the user:

> **Which sections would you like to configure?**
> - Enter section numbers (e.g., `1, 3, 4`) to run specific sections
> - Enter `all` to run everything that isn't already ✅
> - Enter `force all` to re-run everything regardless of status
>
> You can also request modifications (e.g., "run 4 and 5 but use ~/Projects/Kernova as the path").

Wait for the user's response before proceeding.

---

## Step 2: Execute Selected Sections

Run only the sections the user selected. For each section, follow the instructions below. Present proposed changes and confirm before writing. After each section completes, briefly report what was done (one or two lines), then move to the next.

### Section 1: User-Level Settings

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
    },
    "autoUpdate": true
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

### Section 2: Xcode Toolchain

Run `xcode-select -p` and check the output:

- **If it returns `/Applications/Xcode.app/Contents/Developer`** — report as already correct, move on.
- **If it returns anything else** (e.g., `/Library/Developer/CommandLineTools`) — tell the user they need to switch to Xcode by running:
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
  Ask the user to run this command (it requires sudo). Do not proceed to the next section until `xcode-select -p` returns the correct path.

### Section 3: Project Local Settings

#### Step 3a: Locate the project

Check if the Kernova project path exists (default: `~/Developer/GitHub/nicholas-lonsinger/Kernova`). If not, ask the user for the path. Do not proceed until a valid path is confirmed.

#### Step 3b: settings.local.json

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

Present the proposed merged result and confirm before writing.

### Section 4: CLAUDE.local.md

Check if `{kernova}/CLAUDE.local.md` already exists.

- **If it does not exist** — copy the template from `${CLAUDE_PLUGIN_ROOT}/scripts/templates/kernova-CLAUDE.local.md` to `{kernova}/CLAUDE.local.md`. Show the content and confirm before writing.
- **If it exists and matches the template** — report as up to date, move on.
- **If it exists but differs from the template** — show the user a diff between the existing file and the template. Ask whether to overwrite, keep existing, or manually merge.

---

## Step 3: Final Report

After all selected sections are complete, present a compact summary:

```
## Setup Complete

| Section                  | Result              |
|--------------------------|---------------------|
| User-level settings      | ✅ Updated / ✅ Already configured / ⏭️ Skipped |
| Xcode toolchain          | ✅ Correct / ⏭️ Skipped |
| Project local settings   | ✅ Updated / ✅ Already configured / ⏭️ Skipped |
| CLAUDE.local.md          | ✅ Created / ✅ Up to date / ⏭️ Skipped |
```

If any sections were skipped or need attention, note them. Remind the user to run `/setup:statusline` if they also want the custom status line.
