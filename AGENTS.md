# Agents

Pointers for AI coding agents working in this repository.

## Overview

**agent-lens.nvim** is a Neovim plugin (Lua, no compiled deps) that watches a project's filesystem for file changes and displays a live edit timeline with native Neovim diffs. It is agent-agnostic — no IPC or hooks are required.

## Architecture

```
lua/agent-lens/
├── init.lua        — Public API, setup(), commands, orchestration
├── config.lua      — Typed defaults, user option merge (vim.tbl_deep_extend)
├── watcher.lua     — libuv fs_event file watcher (recursive FSEvents on macOS, per-dir inotify on Linux)
├── diff.lua        — Git diff engine: HEAD vs working tree, hunk parsing
├── timeline.lua    — Ordered edit feed data model (add, list, clear, summary)
├── panel.lua       — Timeline sidebar UI (split window, j/k nav, highlights)
├── diff_view.lua   — Side-by-side diff viewer (diffthis on scratch buffers)
└── health.lua      — :checkhealth agent-lens
plugin/
└── agent-lens.lua  — Autoload stub
doc/
└── agent-lens.txt  — Vimdoc help
```

### Data flow

```
filesystem write → vim.uv.fs_event (watcher.lua)
  → debounce (configurable ms)
  → ignore filter (glob patterns)
  → git diff HEAD -- <file> (diff.lua)
  → timeline.add() (timeline.lua)
  → panel.render() (panel.lua)
  → user selects entry → diff_view.open() (diff_view.lua)
```

### Key types

- `AgentLensOpts` — full config schema (see `config.lua`)
- `TimelineEntry` — `{id, timestamp, rel_path, status, stats, agent, diff_cached}`
- `FileDiff` — `{rel_path, status, hunks[], stats, raw}`
- `DiffHunk` — `{old_start, old_count, new_start, new_count, header, lines[]}`

## Development rules

- **Neovim >= 0.10** is the minimum version. Use `vim.uv` (not `vim.loop`).
- **No external dependencies.** Only Neovim builtins, libuv, and git CLI.
- **StyLua** formatting: run `stylua .` before committing. CI enforces `stylua --check`.
- **Luacheck** linting: CI runs `luacheck lua/ plugin/` with `vim` and `jit` as globals.
- **LuaCATS annotations** (`---@class`, `---@param`, `---@return`) on all public functions and types.
- **Immutable patterns**: prefer creating new tables over mutating existing ones (see `timeline.add()`).
- **No Python, no Node, no compiled code.** Pure Lua + git CLI.

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
  -c "lua local cmds = vim.api.nvim_get_commands({}); for _, n in ipairs({'AgentLens','AgentLensClear','AgentLensClose','AgentLensDiff','AgentLensStart','AgentLensStop'}) do assert(cmds[n], n) end; print('OK')" \
  -c "qa!"
```

## Adding a new agent backend

agent-lens is filesystem-based — it does not need per-agent backends. If future work adds agent-specific features (e.g., inferring which agent wrote a file), add a module at `lua/agent-lens/agents/<name>.lua` that exports a detection function:

```lua
--- Detect if this agent is running and identify its edits.
---@param rel_path string
---@return string|nil agent_name
function M.detect(rel_path) end
```

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
