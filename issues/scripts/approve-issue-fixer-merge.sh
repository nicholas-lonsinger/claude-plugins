#!/bin/bash

# PreToolUse hook (matcher: Bash). Auto-approves `gh pr merge …` when — and only
# when — the call comes from this plugin's issue-fixer subagent.
#
# Why: /issues:fix launches issues:issue-fixer agents whose contract explicitly
# includes merging the PR they created. In accept-edits ("auto") mode the merge
# command still hits a permission prompt, which stalls an otherwise unattended
# run mid-queue. Skill-level allowed-tools grants don't propagate into subagents,
# so the plugin grants this one command here instead. Invoking /issues:fix is the
# user's consent to merge; nothing outside that agent is affected.
#
# Scope guards:
#   - agent_type must be this plugin's issue-fixer (no effect on the main
#     conversation or other agents)
#   - command must start with `gh pr merge` and contain no shell metacharacters
#     that could chain or substitute in a second command
#
# Emitting nothing (exit 0, empty output) means "no opinion" — the normal
# permission flow proceeds untouched.

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty')
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

case "$agent_type" in
    issues:issue-fixer|issue-fixer) ;;
    *) exit 0 ;;
esac

case "$cmd" in
    "gh pr merge"|"gh pr merge "*) ;;
    *) exit 0 ;;
esac

case "$cmd" in
    *[';&|<>`$'$'\n']*) exit 0 ;;
esac

printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"issues plugin: gh pr merge auto-approved for the issues:issue-fixer agent"}}'
