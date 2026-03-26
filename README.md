# nicholas-lonsinger-plugins

A collection of Claude Code plugins for developer productivity.

## Installation

Add this marketplace to Claude Code:

```
/plugin marketplace add nicholas-lonsinger/claude-plugins
```

Then install individual plugins:

```
/plugin install setup@nicholas-lonsinger-plugins
```

## Available Plugins

### setup

Environment setup utilities for Claude Code.

**Skills:**

| Skill | Command | Description |
|-------|---------|-------------|
| statusline | `/setup:statusline` | Install a custom status line with git info, context window usage, and rate limit monitoring |

#### Status Line Features

- Model name and output style
- Git branch with worktree detection, dirty/untracked flags, and ahead/behind tracking
- Context window usage percentage with input/output token counts
- Rate limit monitoring for 5-hour and 7-day windows with pace-based color coding

**Requirements:** `jq`, `git`, macOS or Linux

## Adding Plugins

Each plugin lives in its own subdirectory with a `.claude-plugin/plugin.json` manifest. See the `setup/` directory for an example of the expected structure.

## License

MIT
