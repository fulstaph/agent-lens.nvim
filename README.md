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

- **Stable activity timeline** — grouped files, expandable read/edit events, filters and new-activity counts
- **Hunk and full review** — unified hunk float or native `diffthis` in a separate tab, with changed-file navigation
- **In-buffer activity** — recent read ranges and Git `HEAD`-to-disk changed lines are marked without opening the timeline; use `:AgentLensInlineToggle` to hide/show them
- **Follow Agent** — opt-in Zed-style navigation shows code appearing in a live draft, follows the generated lines, and switches to the saved file after execution without replacing unsaved buffers
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

Follow Agent is separate from static activity marks. It uses the current ordinary editor window, moves the cursor to the agent's line, and maintains one current marker. It never force-replaces a modified buffer. Pinned, cursor-bound, scroll-bound, diff, preview, and other special windows are left alone; Follow reuses another safe window in the current tab or opens a non-entered split. Manual navigation pauses Follow; `<leader>ar` resumes at the newest target. Insert hands a draft back to its real source for editing.

## Commands

| Command | Description |
|---------|-------------|
| `:AgentLens` | Toggle the timeline panel (starts watcher if needed) |
| `:AgentLensStart [dir]` | Start the file watcher |
| `:AgentLensStop` | Stop watcher/transports and disable Follow |
| `:AgentLensDiff` | Review selected/current file against HEAD in a separate tab |
| `:AgentLensPreview` | Preview current hunk, or open a read range |
| `:AgentLensPause` | Freeze Follow; keep receiving activity |
| `:AgentLensResume` | Enable/resume Follow at the latest safe target |
| `:AgentLensFollowMode [current\|split]` | Choose mode; no argument toggles |
| `:AgentLensFilter [all\|reads\|edits]` | Choose filter; no argument cycles |
| `:AgentLensStatus` | Show observable activity and channel details |
| `:AgentLensClear` | Clear the timeline and in-buffer activity |
| `:AgentLensInlineToggle` | Hide/show read and write marks in file buffers |
| `:AgentLensFollow` | Toggle live navigation to the active Pi/OMP location |
| `:AgentLensClose` | Close all agent-lens windows |

## Keymaps

### Global

`<leader>al` toggles the timeline, `<leader>af` toggles Follow, and
`<leader>ar` resumes. An empty mapping disables the binding.

### Timeline buffer

| Key | Action |
| --- | --- |
| `j/k`, `]a/[a` | Move selection |
| `<Tab>` | Expand/collapse file |
| `<CR>` | Open latest matching edit in a group, or read range |
| `p` | Preview hunk (reads open their range) |
| `f` | Cycle all/reads/edits |
| `u` | Show only new activity |
| `m` | Mark retained activity seen |
| `g` | Switch files/events view |
| `R`, `q/Esc` | Refresh, close |

File groups preserve event history and selection as new activity arrives.
Successful opens acknowledge matching events; scrolling does not. `+N/-M`
counts use the latest retained edit per file, including when its newest event
is a read. They describe retained HEAD-to-disk comparisons, not an agent-only
or live repository-wide total.

### Follow and review

Follow control is **off**, **following**, or **paused**, independently of
activity. Pausing cancels motion and freezes the visible draft/view while one
bounded newest snapshot replaces the pending one. After success while paused,
explicit resume shows the real source; failure/cancellation discards speculative
content. Closing review never resumes Follow automatically.

Editing commands such as `o`, `cw`, and `s` hand a draft back to its real source
before changing text, even while paused. Unsaved source edits are preserved.

Default `follow.window = "current"` uses a safe current-tab editor window.
`follow.window = "split"` owns one agent split without taking focus; work in
other windows can continue. Closing/reusing it pauses until explicit resume or
mode selection. Inactive tabs freeze and a still-following split catches up on
return. Width 0 uses half the editor; a positive width clamps. User-customized
winbars are preserved. Stopping Follow or switching modes keeps source splits
with unsaved edits and releases the plugin's own winbar. `auto_pause = false`
disables ordinary key-navigation pauses; Insert and unsafe/modal protections still apply.

Hunk preview uses `]h/[h`, `R`, `<CR>` for full review and `q/Esc` to close.
Full review uses `]h/[h`, `]f/[f`, `R`, and `q/Esc`. It opens a separate tab with
the configured split orientation, preserving original splits, views and
unsaved text. Reused/user-added review windows survive close. The originating
view is restored only when it still shows the original buffer.

Review recomputes **current HEAD → disk** from the watched repository. An old
selected event is not a historical patch. Partial line removal is modified;
missing tracked files are deleted; untracked files are added; renames appear as
separate old/new paths. Binary, unsafe, unchanged and unavailable HEAD targets
give a message. Create the first commit to establish a HEAD baseline.
When watching a subdirectory, changed-file navigation stays inside it and uses
paths relative to that watched root.
Streaming writes never select a different review file/hunk for you. Switching the
watched repository clears retained activity so old paths cannot be reviewed
against a different HEAD.

### Activity and transport status

`:AgentLensStatus` shows watched root, control/reason, latest validated activity
and separate metadata/preview channels. Activity labels are Reading, Drafting,
Applying, Settled, Failed and Waiting; Paused takes precedence. Missing logs
mean waiting; an empty socket means listening. Neither proves host liveness.
Valid data advances the receipt time; restart clears recovered errors.

`lens.status()` returns copied metadata only:
`watcher {state, root}`, `follow {control, window, reason}`,
`activity {phase, tool, path, line, call_id}`, and
`metadata/preview {state, last_valid_at, error}` plus preview `peers`.
Metadata states: disabled/waiting/received/error. Preview states:
disabled/listening/receiving/error. Times are Unix seconds; no draft bodies.
`User AgentLensStatusChanged` coalesces discrete changes for optional integrations.

Optional built-in statusline integration (Agent Lens never replaces yours):

```lua
vim.o.statusline = "%{%v:lua.require'agent-lens'.statusline()%}"
```

The returned string escapes statusline percent directives; the reevaluated
expression above renders percent signs in filenames correctly.

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
  timeline = { view = "files", filter = "all" },
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
    preview = true,             -- Show streamed code in a temporary read-only draft
    animation = true,           -- Reveal generated text and ease viewport movement
    animation_ms = 180,         -- Maximum reveal duration per incoming batch
    auto_pause = true,
    window = "current",         -- "current" or "split"
    split = { position = "right", width = 0 },
  },

  keymaps = {
    toggle = "<leader>al",
    follow = "<leader>af",
    resume = "<leader>ar",
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
    follow_cursor = "DiagnosticInfo",
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

## Lua API

```lua
local lens = require("agent-lens")
lens.setup(opts)
lens.start(root)
lens.stop()
lens.toggle()
lens.toggle_follow()        -- boolean enabled
lens.pause_follow()         -- boolean
lens.resume_follow()        -- boolean; enables and starts sources as needed
lens.set_follow_window("split") -- boolean
lens.preview()              -- boolean success
lens.show_diff()            -- boolean success
lens.status()               -- copied StatusSnapshot
lens.statusline()           -- escaped compact string
lens.clear()                -- activity/acknowledgement/pending marks reset
lens.close_all()            -- timeline, review and details windows
```

## How it works

1. On `setup()`, a libuv `fs_event` watcher attaches to the git root directory.
   - macOS: single recursive watcher via native FSEvents.
   - Linux: per-directory `inotify` watchers, recursively attached.
2. File change events are debounced (default 150ms) and filtered against ignore patterns.
3. Each surviving event triggers `git diff HEAD -- <file>` to compute a structured diff with hunk parsing.
4. The diff is stored as a timestamped timeline entry with add/remove stats.
5. The timeline projects retained events into stable file groups (or a flat feed).
6. Preview shows a current unified hunk; full review opens owned HEAD/disk scratch buffers in a separate native diff tab.
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
   `AGENT · pi` as correlated lifecycle records arrive. When the host streams
   edit or write arguments, code appears in a temporary read-only draft and
   the cursor follows the generated lines, including partially typed lines.

Live drafts use a private local Unix socket on macOS and Linux. Draft code
stays in memory; it is never written to the metadata log, a swap file, or the
target file. The preview supports full-file writes, Pi `oldText`/`newText`
replacements, numeric OMP hashline replacements and insertions, and patch
additions or updates with unique source context. Updates are coalesced every
25 ms. Drafts are limited to 1 MiB and 20,000 lines; unsupported or ambiguous
edits fall back to location following. Each Neovim instance has its own socket,
which is removed when Follow stops or Neovim exits.

The draft stays visible while the tool applies its edit, then Follow opens
the actual source buffer from disk. A failure or cancelled stream removes
the draft. Unsaved source buffers keep their text; Follow uses a safe split
when the current buffer has unsaved edits. Set `follow.preview = false` to
use location following without a content receiver.

Drafts reveal changed text progressively with a caret at the generated column
and a highlighted active line. Untouched context stays in place; the viewport
eases when the caret approaches its edge. Incoming batches catch up within
180 ms, including a final batch that arrives just before tool completion.
Set `follow.animation = false` for immediate updates, or adjust
`follow.animation_ms` (0–400 ms). Large changes skip the reveal to stay responsive.

The streamed bridge reads Pi/OMP `message_update` tool-call arguments but
emits metadata only at complete, safe file-section or hunk boundaries, never
per token. `progress` records are edit-only and carry an optional positive
`line` plus a monotonic `sequence` per tool call. Neovim validates phase,
tool, sequence, line, repository containment, `.git`, and symlink safety again.
`start` reconciles speculative metadata, and `tool_result` remains authoritative.
Some providers expose only one complete delta. Its received content can still
be revealed visually; code cannot appear before the host sends it.

The extension writes **only repository-relative paths, bounded lifecycle IDs,
tool names, phases, and optional line/sequence/range metadata** to
`<git-dir>/agent-lens/reads.jsonl` (new files use mode `0600`). It never records
file contents, write text, patches, prompts, raw deltas, tool output, absolute
paths, or secrets. The package uses the same bridge through both
`omp.extensions` and `pi.extensions`; run `npm run test:extension` to verify
the manifest and privacy contract.

Source buffers refresh from disk using Neovim's normal file-reading hooks.
Streamed code appears in a separate `agent-lens://draft/…` buffer and never
overwrites source-buffer contents. Without a content preview, a missing edit
target can still show a location-only draft; when its file appears unmodified,
Follow loads it. If you have unsaved text, Follow keeps it and reports the
conflict. Failed loads are reported rather than presented as successful empty
buffers.

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

Reports Neovim, libuv, Git, watched root and observable transport facts. Use `:AgentLensStatus` for details and `:AgentLensStart` to retry transport errors.

## License

[MIT](LICENSE)
