# Agents

Pointers for AI coding agents working in this repository.

## Overview

**agent-lens.nvim** is a Neovim plugin (Lua) tracking filesystem edits and showing Git `HEAD`-to-disk changed lines inside file buffers. Optional Pi/OMP read-tool events use a bundled JavaScript extension, disabled unless explicitly loaded in the agent and enabled in Neovim.

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
├── read_events.lua — Opt-in JSONL consumer for successful Pi/OMP reads
├── inline.lua      — Read-range/write-line extmarks in ordinary file buffers
└── health.lua      — :checkhealth agent-lens
plugin/
└── agent-lens.lua  — Autoload stub
doc/
└── agent-lens.txt  — Vimdoc help
```

The optional `extensions/pi-read-events.js` listens for successful `read`
tool results and appends relative paths and optional requested line ranges to
`<git-dir>/agent-lens/reads.jsonl`. Neovim polls complete records and validates
paths before rendering. Read entries open the current file at the requested
start line when known; unknown ranges get a file-level label.

### Data flow

```
filesystem write → vim.uv.fs_event (watcher.lua)
  → debounce (configurable ms)
  → ignore filter (glob patterns)
  → git diff HEAD -- <file> (diff.lua)
  → timeline.add() + panel.render()
  → checktime → inline.record_write() (inline.lua)
  → user selects entry → diff_view.open() (diff_view.lua)

Pi/OMP read → successful built-in read tool result → metadata-only JSONL
  → read_events.poll() → timeline.add() + inline.record_read()
```

### Key types

- `AgentLensOpts` — full config schema (see `config.lua`)
- `TimelineEntry` — `{id, timestamp, rel_path, status, kind?, stats, agent, range?, diff_cached}`; `kind="read"` has no diff
- `FileDiff` — `{rel_path, status, hunks[], stats, raw}`
- `DiffHunk` — `{old_start, old_count, new_start, new_count, header, lines[]}`

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
  -c "lua local cmds = vim.api.nvim_get_commands({}); for _, n in ipairs({'AgentLens','AgentLensClear','AgentLensClose','AgentLensDiff','AgentLensInlineToggle','AgentLensStart','AgentLensStop'}) do assert(cmds[n], n) end; print('OK')" \
  -c "qa!"
```

The read path and in-buffer overlays have behavioral tests:

```bash
nvim --headless -u NONE -l tests/read_events.lua
nvim --headless -u NONE -l tests/inline.lua
node tests/pi-read-events.test.mjs
```

## Adding an agent read source

Filesystem edits stay agent-agnostic. For read events, mirror the Pi extension:
emit one newline-delimited JSON object with `v: 1`, `kind: "read"`, a
repository-relative `path`, an `agent` label, and optionally a validated
`range: { start, end }` of requested 1-based lines to the active Git directory's
`agent-lens/reads.jsonl`. Never include file contents or secrets. Only emit
successful reads, validate the repository boundary at the source, and keep the
Neovim consumer's validation in place.

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
