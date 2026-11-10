---
name: name-session
description: Rename this Claude session to "<issue number> <2-3 word summary>", e.g. "1833 Ephemeral setting revert". Takes an optional issue number; without one, uses the issue the session is working on.
disable-model-invocation: true
---

# Name the session

1. **Issue number.** The argument, if given (strip a leading `#`). Otherwise the GitHub issue this conversation is working on. If there is none or more than one, ask which.
2. **Summary.** Two or three words, title case on the first word only, naming the problem the issue is about, not the fix (`Ephemeral setting revert`, not `Add banner`). Read the issue's title with `gh api repos/{owner}/{repo}/issues/<N> --jq .title` if the conversation hasn't shown it.
3. **Rename.** Call `get_session` (claude-code-remote MCP server) with no `session_id` to get this session's id, then `set_session_title` with that id and the title `<N> <summary>`, no `#`, no punctuation between.
4. Reply with the new title in one line.

When the claude-code-remote tools are absent (a session without Remote Control), say so; there is no other way to rename the session from inside it.
