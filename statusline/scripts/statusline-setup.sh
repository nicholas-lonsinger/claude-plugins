#!/bin/bash

# Runs at every SessionStart while the statusline plugin is enabled. Makes "enable the
# plugin" the entire install — there is no skill.
#
# The renderers live at a versioned, ephemeral path: CLAUDE_PLUGIN_ROOT changes on every
# update and old versions are pruned ~7 days later. We bridge to them from the STABLE
# plugin data dir (CLAUDE_PLUGIN_DATA persists across versions), re-pointing symlinks there
# each session so settings.json can reference fixed paths that always resolve to the
# current renderers. Keeping the pointers in the data dir — not ~/.claude — follows the
# repo rule that plugin-owned state lives under the plugin, never loose in ~/.claude.

data="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/statusline-nicholas-lonsinger-plugins}"
mkdir -p "$data" 2>/dev/null

# Re-point one stable symlink at this version's renderer, then echo the ~-relative path for
# settings.json. Touch the link only when it is absent or already a symlink — never clobber
# a real file someone dropped there. A link left dangling by a pruned old version fails -e,
# so it gets repointed; that is the ordinary upgrade path, not an error case.
#
# Echoes nothing and returns non-zero when the link cannot be made to resolve, so a broken
# bridge is skipped rather than written into settings.json as a dead path. The bridges are
# independent: a failure on one must not stop the other from being configured.
bridge() {
    local target="$1" link="$2"
    if { [ -L "$link" ] || [ ! -e "$link" ]; } && [ "$(readlink "$link" 2>/dev/null)" != "$target" ]; then
        ln -sfn "$target" "$link" 2>/dev/null
    fi
    [ -e "$link" ] || return 1
    printf '%s' "${link/#$HOME/~}"
}

main_cmd="$(bridge "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh" "$data/statusline.sh")"
sub_cmd="$(bridge "${CLAUDE_PLUGIN_ROOT}/scripts/subagent-statusline.sh" "$data/subagent-statusline.sh")"

# Write each key only when it is entirely absent, so a user's own renderer — or a deliberate
# null to disable one — survives untouched. Both keys go through a single filter and a
# single rename: two sequential writes would double the window in which a concurrent
# session reads stale state and drops the other key, and could crash between them leaving
# one key written and one not. Bail quietly if jq is missing or the file is absent/invalid.
settings="$HOME/.claude/settings.json"
[ -n "$main_cmd$sub_cmd" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ -f "$settings" ] || exit 0
jq -e . "$settings" >/dev/null 2>&1 || exit 0

# Temp file alongside the target so the replacing mv is a same-filesystem rename, and so
# atomic. mktemp's default TMPDIR can sit on another volume, where mv degrades to
# copy+unlink and a crash mid-copy truncates settings.json.
tmp="$(mktemp "${settings}.XXXXXX" 2>/dev/null)" || exit 0
trap 'rm -f "$tmp"' EXIT

# has() rather than //=, which would fire on an explicit null and overwrite a deliberate
# "disable this renderer". An empty $cmd means that bridge failed, so its key is skipped.
if jq --arg main "$main_cmd" --arg sub "$sub_cmd" '
      def ensure($key; $cmd):
        if $cmd == "" or has($key) then . else . + {($key): {type: "command", command: $cmd}} end;
      ensure("statusLine"; $main)
      | ensure("subagentStatusLine"; $sub)
    ' "$settings" > "$tmp"; then
    mv "$tmp" "$settings"
fi

exit 0
