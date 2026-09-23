<div align="center">

# agent-lens.nvim

**Watch AI agent file edits in real-time inside Neovim.**

[![CI](https://github.com/fulstaph/agent-lens.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/fulstaph/agent-lens.nvim/actions/workflows/ci.yml)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

---

Run any AI coding agent (Pi, Claude Code, Codex, Copilot CLI, OpenCode, …) in a terminal while **agent-lens** tracks every file edit in a live timeline inside Neovim. Select any entry to open a native side-by-side diff — full syntax highlighting, your colorscheme, your keymaps.

**Agent-agnostic.** No hooks or agent-side config needed. The plugin watches the filesystem via libuv and diffs against `git HEAD`. Any process that writes files is tracked automatically.

## Features

- **Live edit timeline** — chronological feed of every file change with `+N / -M` stats
- **Native Neovim diffs** — `diffthis` side-by-side (HEAD vs working tree) with full Tree-sitter highlighting
- **Zero agent coupling** — works with Pi, Claude Code, Codex CLI, Copilot CLI, OpenCode, Aider, or a human in another terminal
- **Fast** — macOS uses native FSEvents recursive watching; Linux uses per-directory `inotify` via libuv; all events debounced
- **Configurable** — panel position, diff layout, ignore patterns, keymaps, highlight groups

## Requirements

- Neovim >= 0.10
- git
- A project under git version control

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "fulstaph/agent-lens.nvim",
  event = "VeryLazy",
  keys = {
    { "<leader>al", "<cmd>AgentLens<cr>", desc = "Toggle Agent Lens" },
    { "<leader>ad", "<cmd>AgentLensDiff<cr>", desc = "Agent Lens: Show Diff" },
    { "<leader>ac", "<cmd>AgentLensClear<cr>", desc = "Agent Lens: Clear Timeline" },
  },
  opts = {
    agent_name = "pi",
  },
  config = function(_, opts)
    require("agent-lens").setup(opts)
  end,
}
```

### Local development

```lua
{
  dir = "~/agent-lens.nvim",
  -- ... same keys/opts/config as above
}
```

## Usage

1. Open your project in Neovim.
2. The watcher starts automatically if you're in a git repo.
3. Run your AI agent in another terminal — edits appear in the timeline as they land.
4. Press `<leader>al` to toggle the timeline panel.
5. Navigate with `j`/`k`, press `<CR>` to open a side-by-side diff.

## Commands

| Command | Description |
|---------|-------------|
| `:AgentLens` | Toggle the timeline panel (starts watcher if needed) |
| `:AgentLensStart [dir]` | Start the file watcher |
| `:AgentLensStop` | Stop the file watcher |
| `:AgentLensDiff` | Open diff for the selected timeline entry |
| `:AgentLensClear` | Clear the timeline |
| `:AgentLensClose` | Close all agent-lens windows |

## Keymaps

### Global

| Key | Action |
|-----|--------|
| `<leader>al` | Toggle timeline panel |
| `]a` | Next edit in timeline |
| `[a` | Previous edit in timeline |

### Timeline buffer

| Key | Action |
|-----|--------|
| `j` / `k` | Navigate entries |
| `<CR>` | Open diff for selected entry |
| `q` | Close timeline |
| `R` | Refresh |

## Configuration

All options with their defaults:

```lua
require("agent-lens").setup({
  enabled = true,                -- Auto-start watching on setup
  watch_dir = nil,               -- nil = auto-detect git root or cwd
  diff_source = "git",           -- How to compute diffs
  debounce_ms = 150,             -- Debounce file change events (ms)
  max_timeline_entries = 200,    -- Max entries in the timeline
  timeline_position = "right",   -- "right", "left", or "bottom"
  timeline_width = 42,           -- Width of the timeline panel
  timeline_height = 15,          -- Height (when position = "bottom")
  diff_layout = "vertical",     -- "vertical" or "horizontal"
  auto_open_diff = false,        -- Auto-open diff on each new edit
  agent_name = "agent",          -- Display name for the agent

  keymaps = {
    toggle = "<leader>al",
    next_edit = "]a",
    prev_edit = "[a",
    open_diff = "<CR>",
    close = "q",
    refresh = "R",
  },

  highlights = {
    added = "DiffAdd",
    removed = "DiffDelete",
    changed = "DiffChange",
    header = "Title",
    timeline_file = "Directory",
    timeline_time = "Comment",
    timeline_agent = "Keyword",
    timeline_selected = "CursorLine",
  },

  filter = {
    ignore_patterns = {
      "*.swp", "*.swo", "*~", "*.pyc",
      "__pycache__/**", ".git/**",
      "node_modules/**", ".DS_Store",
      "*.lock", "lazy-lock.json",
    },
    min_change_bytes = 1,
  },
})
```

## How it works

1. On `setup()`, a libuv `fs_event` watcher attaches to the git root directory.
   - macOS: single recursive watcher via native FSEvents.
   - Linux: per-directory `inotify` watchers, recursively attached.
2. File change events are debounced (default 150ms) and filtered against ignore patterns.
3. Each surviving event triggers `git diff HEAD -- <file>` to compute a structured diff with hunk parsing.
4. The diff is stored as a timestamped timeline entry with add/remove stats.
5. The timeline panel renders entries newest-first with relative timestamps.
6. Selecting an entry opens two scratch buffers (HEAD content vs working tree) in `diffthis` mode with full syntax highlighting.
7. Open Neovim buffers auto-reload via `checktime` autocmds so you see changes live.

## Health check

```vim
:checkhealth agent-lens
```

Verifies Neovim version, libuv availability, git, git repo detection, and watcher state.

## License

[MIT](LICENSE)
