#!/bin/bash

# Runs at every SessionStart while the statusline plugin is enabled. Makes "enable the
# plugin" the entire install — there is no skill.
#
# The renderer lives at a versioned, ephemeral path: CLAUDE_PLUGIN_ROOT changes on every
# update and old versions are pruned ~7 days later. We bridge to it from the STABLE plugin
# data dir (CLAUDE_PLUGIN_DATA persists across versions), re-pointing a symlink there each
# session so settings.json can reference one fixed path that always resolves to the current
# renderer. Keeping the pointer in the data dir — not ~/.claude — follows the repo rule that
# plugin-owned state lives under the plugin, never loose in the user's ~/.claude.

target="${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh"
data="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/statusline-nicholas-lonsinger-plugins}"
link="$data/statusline.sh"

mkdir -p "$data"

# Re-point the stable symlink to this version's renderer. Touch the path only if it's absent
# or already a symlink — never clobber a real file someone dropped there.
if { [ -L "$link" ] || [ ! -e "$link" ]; } && [ "$(readlink "$link" 2>/dev/null)" != "$target" ]; then
    ln -sfn "$target" "$link"
fi

# Auto-write the statusLine key into settings.json if it is entirely absent. Never overwrite
# an existing statusLine (respects a user's own custom status line). Point it at the stable
# data-dir path, ~-relative so it's portable across machines. Atomic write; bail quietly if
# jq is missing or the file is absent/invalid.
settings="$HOME/.claude/settings.json"
cmd="${link/#$HOME/~}"
if command -v jq >/dev/null 2>&1 && [ -f "$settings" ] && jq -e . "$settings" >/dev/null 2>&1; then
    if [ "$(jq 'has("statusLine")' "$settings")" = "false" ]; then
        tmp="$(mktemp)"
        if jq --arg cmd "$cmd" '. + {statusLine: {type: "command", command: $cmd}}' "$settings" > "$tmp"; then
            mv "$tmp" "$settings"
        else
            rm -f "$tmp"
        fi
    fi
fi

exit 0
