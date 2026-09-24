<div align="center">

# agent-lens.nvim

**Watch AI agent file edits in real-time inside Neovim.**

[![CI](https://github.com/fulstaph/agent-lens.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/fulstaph/agent-lens.nvim/actions/workflows/ci.yml)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

---

Run a coding agent beside Neovim: agent-lens shows filesystem edits in a live timeline, highlights changed lines, and opens native diffs against Git `HEAD`. With the optional Pi/OMP bridge, it can also mark successful reads and follow the agent across files as it reads, edits, and writes.

Filesystem edits need no agent integration. Exact live locations cannot be inferred from filesystem notifications, so Follow Agent uses metadata-only Pi/OMP tool events. The generic filesystem channel still cannot identify which process made an edit.

## Features

- **Live edit timeline** — chronological feed of every file change with `+N / -M` stats
- **Native Neovim diffs** — `diffthis` side-by-side (HEAD vs working tree) with full Tree-sitter highlighting
- **In-buffer activity** — recent read ranges and Git `HEAD`-to-disk changed lines are marked without opening the timeline; use `:AgentLensInlineToggle` to hide/show them
- **Follow Agent** — opt-in Zed-style navigation opens the active Pi/OMP file, marks one current location, and labels safe streamed progress as `drafting`, execution as `applying`, and settled results as `AGENT · pi` without replacing unsaved buffers
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
    { "<leader>af", "<cmd>AgentLensFollow<cr>", desc = "Agent Lens: Follow Agent" },
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
### Pi/OMP bridge package

The repository is also a dependency-free dual-host Pi/OMP package. Install it
once, then restart the Pi or OMP session:

```bash
omp install github:fulstaph/agent-lens.nvim
pi install git:github.com/fulstaph/agent-lens.nvim
```

For local development from this checkout:

```bash
omp install .
pi install .
```

The manifest exposes the same `extensions/pi-read-events.js` entry through both
`omp.extensions` and `pi.extensions`. Verify the package and bridge locally
with `npm run test:extension`; the bridge has no runtime dependencies or
bundled host API package.

## Usage

1. Open your project in Neovim.
2. The watcher starts automatically if you're in a git repo.
3. Run your agent in another terminal — writes appear in the timeline and changed lines are highlighted in open file buffers.
4. Press `<leader>al` to toggle the timeline panel; the in-buffer marks do not require the panel.
5. With the Pi/OMP bridge loaded, press `<leader>af` to follow or unfollow the agent's current read/edit/write location.
6. Navigate the timeline with `j`/`k`; `<CR>` opens a diff for an edit or the current file for a read.

In-file write highlights show the current **Git `HEAD` → disk** added/modified lines, not proof that the agent authored those lines. Pure deletions get a nearby `− deleted` label. Read highlights show the **last requested range** when the tool supplies one; a read without a known range gets a file-level label instead. Marks are hidden while a buffer has unsaved local edits, and `:AgentLensClear` removes them.

Follow Agent is separate from static activity marks. It uses the current ordinary editor window, moves the cursor to the agent's line, and maintains one current marker. It never force-replaces a modified buffer. Pinned, cursor-bound, scroll-bound, diff, preview, and other special windows are left alone; Follow reuses another safe window in the current tab or opens a non-entered split. Toggle Follow off to navigate independently.

## Commands

| Command | Description |
|---------|-------------|
| `:AgentLens` | Toggle the timeline panel (starts watcher if needed) |
| `:AgentLensStart [dir]` | Start the file watcher |
| `:AgentLensStop` | Stop the file watcher |
| `:AgentLensDiff` | Open diff for the selected timeline entry |
| `:AgentLensClear` | Clear the timeline and in-buffer activity |
| `:AgentLensInlineToggle` | Hide/show read and write marks in file buffers |
| `:AgentLensFollow` | Toggle live navigation to the active Pi/OMP location |
| `:AgentLensClose` | Close all agent-lens windows |

## Keymaps

### Global

| Key | Action |
|-----|--------|
| `<leader>al` | Toggle timeline panel |
| `<leader>af` | Toggle Follow Agent |
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
  reads = {
    enabled = false,            -- Opt in to Pi/OMP read-tool events
    interval_ms = 100,          -- Poll metadata every 100 ms
  },
  inline = {
    enabled = true,             -- Show latest activity in source buffers
  },
  follow = {
    enabled = false,            -- Opt in to live Pi/OMP navigation
  },

  keymaps = {
    toggle = "<leader>al",
    follow = "<leader>af",
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
    follow = "CursorLine",
    follow_label = "DiagnosticInfo",
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
7. Follow reloads unmodified target buffers from disk through Neovim's normal file readers. Other open buffers use `checktime` autocmds.
8. The optional Pi/OMP bridge appends correlated metadata-only tool locations. Follow Agent navigates the current safe editor window and cursor, keeps exactly one marker, and ignores late completions from older parallel calls.

## Agent setup guides

Filesystem edits from any process appear without hooks. Successful read activity and Follow Agent require the bundled Pi/OMP extension; enable `reads`, `follow`, or both in Neovim.

### Pi agent / Oh My Pi (OMP)

Run Pi or OMP in another terminal in the same Git repository; filesystem
edits appear without hooks. For read activity and Follow Agent, opt in on both
sides:

1. In your LazyVim plugin spec, opt in and restart Neovim:
   ```lua
   opts = {
     agent_name = "pi",
     reads = { enabled = true },
     follow = { enabled = true },
   }
   ```
2. Install the bridge package, then restart the Pi or OMP session:
   ```bash
   omp install github:fulstaph/agent-lens.nvim
   pi install git:github.com/fulstaph/agent-lens.nvim
   ```
   For local development from a checkout, use `omp install .` or `pi install .`.
   The unchanged one-session fallback is:
   ```bash
   omp --extension /path/to/agent-lens.nvim/extensions/pi-read-events.js
   # or:
   pi --extension /path/to/agent-lens.nvim/extensions/pi-read-events.js
   ```
3. Trigger a built-in `read`, `edit`, or `write`. Follow Agent shows one
   marker whose label moves from `drafting` to `applying` to settled
   `AGENT · pi` as correlated lifecycle records arrive.

The streamed bridge reads Pi/OMP `message_update` tool-call arguments but
emits metadata only at complete, safe file-section or hunk boundaries, never
per token. `progress` records are edit-only and carry an optional positive
`line` plus a monotonic `sequence` per tool call. Neovim validates phase,
tool, sequence, line, repository containment, `.git`, and symlink safety again.
`start` reconciles speculative metadata, and `tool_result` remains authoritative.
Some providers expose only one complete delta, so Follow makes one jump rather
than fabricating animation.

The extension writes **only repository-relative paths, bounded lifecycle IDs,
tool names, phases, and optional line/sequence/range metadata** to
`<git-dir>/agent-lens/reads.jsonl` (new files use mode `0600`). It never records
file contents, write text, patches, prompts, raw deltas, tool output, absolute
paths, or secrets. The package uses the same bridge through both
`omp.extensions` and `pi.extensions`; run `npm run test:extension` to verify
the manifest and privacy contract.

Follow Agent refreshes source buffers only from files on disk, using Neovim's
normal file-reading hooks. It never pastes streamed edit bodies, adds virtual
diff lines, or overwrites unsaved buffer contents. A missing draft is not attached
to Neovim's file-created warning; when its file appears unmodified, Follow loads
it. If you have unsaved text, Follow keeps that draft and reports the conflict.
Failed loads are reported rather than presented as successful empty buffers.

Follow does not switch window focus, create timeline entries, or clear static
activity marks. A failed active call clears its marker; a late completion from
an older parallel call cannot replace a newer location.

Remove the package or direct `--extension` loading to stop producing metadata.
`reads.enabled = false` disables static read activity; `follow.enabled = false`
disables automatic navigation. The local JSONL path history remains until you
delete the file.

### Claude Code

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) writes files via `Edit` and `Write` tool calls.

```bash
# In a separate terminal, same project directory:
claude
```

```lua
opts = { agent_name = "claude" }
```

For pre-write interception (approve/reject before disk write), pair with [code-preview.nvim](https://github.com/Cannon07/code-preview.nvim). agent-lens complements it by providing the post-write timeline and diff history.

### OpenAI Codex CLI

```bash
codex
```

```lua
opts = { agent_name = "codex" }
```

### Aider

```bash
aider
```

```lua
opts = { agent_name = "aider" }
```

### Any other agent or process

If it writes files in a git repo, agent-lens tracks it. No integration code required.

```lua
opts = { agent_name = "my-agent" }
```

### Multi-agent workflows

When multiple agents run simultaneously, filesystem edits still share one unattributed timeline. Follow Agent uses the latest correlated event in the Pi/OMP metadata feed; one marker is shown at a time.

## Health check

```vim
:checkhealth agent-lens
```

Verifies Neovim version, libuv availability, git, git repo detection, and watcher state.

## License

[MIT](LICENSE)
