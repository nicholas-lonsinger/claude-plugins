# Claude Plugins

This repo contains Claude Code plugins published via the marketplace.

## Version Bumping (Required)

When committing changes to any plugin (new skills, modified skills, config changes), you **must** bump the `version` field in **both** version files before committing. The plugin manager uses these versions to detect updates — if they aren't bumped, other instances won't pull the change.

- **Patch bump** (e.g. 1.1.0 -> 1.1.1): bug fixes, wording changes, minor tweaks
- **Minor bump** (e.g. 1.1.0 -> 1.2.0): new skills, new features, meaningful additions
- **Major bump** (e.g. 1.2.0 -> 2.0.0): breaking changes, restructuring

Both files must have matching versions:
- `.claude-plugin/marketplace.json` (marketplace index)
- `<plugin>/.claude-plugin/plugin.json` (plugin manifest)

## Repo Structure

```
.claude-plugin/marketplace.json   # Marketplace index — lists all plugins
<plugin>/                         # One directory per plugin (statusline, gittools, issues, claude-memory-sync)
  .claude-plugin/plugin.json      # Plugin manifest (name, version, component paths)
  skills/<skill-name>/SKILL.md    # Skills (invoked as /<plugin>:<skill-name>)
  scripts/                        # Supporting scripts used by skills and hooks
  hooks/hooks.json                # Session hooks (optional; auto-active when plugin enabled)
  templates/                      # Files skills copy out to stable paths (optional)
  tests/<name>.sh                 # Test harness (optional; CI runs every one it finds)
.github/workflows/checks.yml      # CI: shell lint + JSON parse + plugin test harnesses
.shellcheckrc                     # Project-wide shellcheck directives (follow sourced libs)
```

Plugins install as isolated per-plugin copies and cannot reference each
other's files.

## Checks

CI (`checks.yml`) runs on every PR and push to `main`: `bash -n` +
`shellcheck` over **every** tracked script (project-wide directives live in
`.shellcheckrc` — new scripts get coverage automatically, keep them
warning-free), `jq empty` over every tracked JSON manifest, and **every**
tracked `<plugin>/tests/*.sh` harness. Harnesses are discovered by glob, not
listed, so a new one runs from the moment it is committed. Run the same
locally before pushing:

```bash
git ls-files '*.sh' | xargs shellcheck
git ls-files '*.json' | xargs -n1 jq empty
git ls-files '*/tests/*.sh' | xargs -n1 bash
```

## Writing a Test Harness

A harness is a plain script that CI can run as one step, so it owns its own
reporting and exit status: `set -u` without `set -e` (one failed assertion
reports and the run continues), `ok`/`fail` counters, and `[ "$FAIL" -eq 0 ]`
as the last line.

Harnesses must be hermetic — they run on a contributor's machine as readily as
on a runner. Build fixtures under `${TMPDIR:-/tmp}` and remove them on exit,
and neutralize the session environment the scripts under test read: Claude Code
exports `CLAUDE_PLUGIN_DATA`, and a hook that resolves its state dir from that
variable will reach straight past a scratch `$HOME` to the contributor's real
data. Anything a script under test resolves from the environment — `$HOME` for
git's global config included — has to be pinned by the harness, or the run
reports on the machine rather than on the code.

## Adding a New Skill

1. Create `<plugin>/skills/<skill-name>/SKILL.md`
2. Add any supporting scripts/templates under `<plugin>/scripts/`
3. Add the skill keyword to `<plugin>/.claude-plugin/plugin.json` keywords array
4. Bump the version in both `.claude-plugin/marketplace.json` and `<plugin>/.claude-plugin/plugin.json` (minor bump, must match)
5. Commit and push
