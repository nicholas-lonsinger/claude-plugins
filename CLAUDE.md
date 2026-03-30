# Claude Plugins

This repo contains Claude Code plugins published via the marketplace.

## Version Bumping (Required)

When committing changes to any plugin (new skills, modified skills, config changes), you **must** bump the `version` field in **both** version files before committing. The plugin manager uses these versions to detect updates — if they aren't bumped, other instances won't pull the change.

- **Patch bump** (e.g. 1.1.0 -> 1.1.1): bug fixes, wording changes, minor tweaks
- **Minor bump** (e.g. 1.1.0 -> 1.2.0): new skills, new features, meaningful additions
- **Major bump** (e.g. 1.2.0 -> 2.0.0): breaking changes, restructuring

Both files must have matching versions:
- `.claude-plugin/marketplace.json` (marketplace index)
- `setup/.claude-plugin/plugin.json` (plugin manifest)

## Repo Structure

```
.claude-plugin/marketplace.json   # Marketplace index — lists all plugins
setup/                            # "setup" plugin
  .claude-plugin/plugin.json      # Plugin manifest (name, version, skills path)
  skills/                         # Skills directory
    statusline/SKILL.md           # Status line setup skill
    kernova/SKILL.md              # Kernova machine setup skill
  scripts/                        # Supporting scripts used by skills
```

## Adding a New Skill

1. Create `setup/skills/<skill-name>/SKILL.md`
2. Add any supporting scripts/templates under `setup/scripts/`
3. Add the skill keyword to `setup/.claude-plugin/plugin.json` keywords array
4. Bump the version in both `.claude-plugin/marketplace.json` and `setup/.claude-plugin/plugin.json` (minor bump, must match)
5. Commit and push
