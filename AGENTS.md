# Agents

Pointers for AI coding agents working in this repository.

## Overview

**agent-lens.nvim** is a Neovim plugin (Lua) tracking filesystem edits and showing Git `HEAD`-to-disk changed lines inside file buffers. An optional Pi/OMP JavaScript extension publishes metadata-only successful reads and correlated read/edit/write locations for Zed-style Follow Agent navigation.

## Architecture

```
lua/agent-lens/
├── init.lua        — Public API, setup(), commands, orchestration
├── config.lua      — Typed defaults, user option merge (vim.tbl_deep_extend)
├── watcher.lua     — libuv fs_event file watcher (recursive FSEvents on macOS, per-dir inotify on Linux)
├── diff.lua        — Git diff engine: HEAD vs working tree, hunk parsing
├── timeline.lua    — Ordered edit feed data model (add, list, clear, summary)
├── panel.lua       — Timeline sidebar UI (split window, j/k nav, highlights)
├── diff_view.lua   — Side-by-side edit diff viewer
├── read_events.lua — JSONL trust boundary for Pi/OMP reads and locations
├── inline.lua      — Persistent read-range/write-line extmarks
├── follow.lua      — One live agent marker, safe window selection, viewport following
└── health.lua      — :checkhealth agent-lens
plugin/
└── agent-lens.lua  — Autoload stub
doc/
└── agent-lens.txt  — Vimdoc help
```

The optional `extensions/pi-read-events.js` listens for `read`, `edit`, and
`write` tool lifecycles. It appends correlated repository-relative locations
and successful read ranges to `<git-dir>/agent-lens/reads.jsonl`. Neovim polls
complete records, validates them again, and fans them into independent
timeline, inline, and follow projections.

### Data flow

```
filesystem write → vim.uv.fs_event (watcher.lua)
  → debounce (configurable ms)
  → ignore filter (glob patterns)
  → git diff HEAD -- <file> (diff.lua)
  → timeline.add() + panel.render()
  → checktime → inline.record_write() (inline.lua)
  → user selects entry → diff_view.open() (diff_view.lua)

Pi/OMP tool_call/result → metadata-only JSONL
  → read_events.poll() validates repository paths and lifecycle fields
  → successful read → timeline.add() + inline.record_read()
  → correlated location → follow.record_location()
  → one safe editor window + one agent_lens_follow extmark
```

### Key types

- `AgentLensOpts` — full config schema (see `config.lua`)
- `TimelineEntry` — `{id, timestamp, rel_path, status, kind?, stats, agent, range?, diff_cached}`; `kind="read"` has no diff
- `FileDiff` — `{rel_path, status, hunks[], stats, raw}`
- `DiffHunk` — `{old_start, old_count, new_start, new_count, header, lines[]}`
- `AgentLocation` — `{call_id, phase, tool, path?, line?, agent}` normalized by `read_events.lua`

## Development rules

- **Neovim >= 0.10** is the minimum version. Use `vim.uv` (not `vim.loop`).
- **No external dependencies.** Only Neovim builtins, libuv, and git CLI.
- **StyLua** formatting: run `stylua .` before committing. CI enforces `stylua --check`.
- **Luacheck** linting: CI runs `luacheck lua/ plugin/` with `vim` and `jit` as globals.
- **LuaCATS annotations** (`---@class`, `---@param`, `---@return`) on all public functions and types.
- **Immutable patterns**: prefer creating new tables over mutating existing ones (see `timeline.add()`).
- **No compiled runtime dependency.** Lua + Git for Neovim; the optional Pi/OMP bridge uses Node-compatible JS APIs inside the agent runtime.

## Testing

Tests run headless in CI across Neovim v0.10.4, stable, and nightly:

```bash
# Load test
nvim --headless -u NONE -c "set rtp+=." \
  -c "lua require('agent-lens').setup({ enabled = false })" \
  -c "lua print('OK')" -c "qa!"

# Verify all commands register
nvim --headless -u NONE -c "set rtp+=." \
  -c "lua require('agent-lens').setup({ enabled = false })" \
  -c "lua local cmds = vim.api.nvim_get_commands({}); for _, n in ipairs({'AgentLens','AgentLensClear','AgentLensClose','AgentLensDiff','AgentLensFollow','AgentLensInlineToggle','AgentLensStart','AgentLensStop'}) do assert(cmds[n], n) end; print('OK')" \
  -c "qa!"
```

The metadata path, follow projection, and in-buffer overlays have behavioral
tests:

```bash
nvim --headless -u NONE -l tests/read_events.lua
nvim --headless -u NONE -l tests/follow.lua
nvim --headless -u NONE -l tests/inline.lua
node tests/pi-read-events.test.mjs
```

## Adding an agent metadata source

Filesystem edits stay agent-agnostic. A successful read record uses `v: 1`,
`kind: "read"`, a repository-relative `path`, an `agent`, and optional
`range: { start, end }`. A live location uses `kind: "location"`,
`phase: "start"|"success"|"error"`, `tool: "read"|"edit"|"write"`, a bounded
`toolCallId`, optional safe `path`, and optional positive 1-based `line`.
Write complete JSON objects to the active Git directory's
`agent-lens/reads.jsonl`. Never include contents, patches, prompts, tool
output, absolute paths, or secrets. Validate the repository boundary at the
source and keep the Neovim consumer's independent validation in place.

## File conventions

| File | Role |
|------|------|
| `README.md` | User-facing docs, installation, agent setup guides |
| `AGENTS.md` | This file — agent/AI development context |
| `doc/agent-lens.txt` | `:help agent-lens` vimdoc |
| `.github/workflows/ci.yml` | CI: stylua, luacheck, headless tests |
| `stylua.toml` | Formatter config (2-space indent, 100 col) |
| `.luacheckrc` | Linter config |

## Commit conventions

```
<type>: <description>
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `ci`, `perf`
