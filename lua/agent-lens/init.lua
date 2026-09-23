--- agent-lens.nvim — Watch AI agent file edits in real-time inside Neovim.
---
--- Usage:
---   require("agent-lens").setup({ agent_name = "pi" })
---
--- Commands:
---   :AgentLens        — Toggle the timeline panel
---   :AgentLensStart   — Start watching
---   :AgentLensStop    — Stop watching
---   :AgentLensClear   — Clear the timeline
---   :AgentLensDiff    — Open diff for selected entry

local config = require("agent-lens.config")
local watcher = require("agent-lens.watcher")
local diff_engine = require("agent-lens.diff")
local timeline = require("agent-lens.timeline")
local panel = require("agent-lens.panel")
local diff_view = require("agent-lens.diff_view")
local read_events = require("agent-lens.read_events")

local M = {}

---@type string|nil Git root of the watched project
M._root = nil

--- Handle a file change event from the watcher.
---@param rel_path string Relative path from project root
---@param events table Event flags from libuv
local function on_file_change(rel_path, events)
  if not M._root then
    return
  end

  -- Skip binary files (quick heuristic: check extension)
  local ext = rel_path:match("%.([^.]+)$")
  local binary_exts = {
    png = true,
    jpg = true,
    jpeg = true,
    gif = true,
    bmp = true,
    ico = true,
    svg = true,
    woff = true,
    woff2 = true,
    ttf = true,
    eot = true,
    mp3 = true,
    mp4 = true,
    mov = true,
    avi = true,
    zip = true,
    gz = true,
    tar = true,
    pdf = true,
    exe = true,
    dll = true,
    so = true,
    dylib = true,
    o = true,
    a = true,
  }
  if ext and binary_exts[ext:lower()] then
    return
  end

  -- Compute diff
  local file_diff = diff_engine.file_diff(M._root, rel_path)

  if events.deleted then
    timeline.add({
      rel_path = rel_path,
      status = "deleted",
      stats = { added = 0, removed = 0 },
    })
  elseif file_diff then
    timeline.add({
      rel_path = rel_path,
      status = file_diff.status,
      stats = file_diff.stats,
      diff = file_diff,
    })
  else
    -- No diff — file matches HEAD, skip
    return
  end

  -- Refresh the panel if it's open
  if panel.is_open() then
    panel.render()
  end

  -- Auto-open diff if configured
  if config.options.auto_open_diff and file_diff then
    local latest = timeline.entries[#timeline.entries]
    if latest then
      diff_view.open(latest)
    end
  end

  -- Also trigger checktime so open buffers reload
  vim.cmd("silent! checktime")
end

--- Start watching the project for file changes.
---@param root? string Project root (auto-detected from git or cwd)
function M.start(root)
  root = root or config.options.watch_dir or diff_engine.git_root() or vim.fn.getcwd()
  M._root = root

  watcher.start(root, on_file_change)
  if config.options.reads.enabled then
    read_events.start(root)
  end
  vim.notify(
    string.format("[agent-lens] Watching %s", vim.fn.fnamemodify(root, ":~")),
    vim.log.levels.INFO
  )
end

--- Stop watching.
function M.stop()
  watcher.stop()
  read_events.stop()
  M._root = nil
  vim.notify("[agent-lens] Stopped watching", vim.log.levels.INFO)
end

--- Toggle the timeline panel. Starts the watcher if not running.
function M.toggle()
  if not watcher.is_running() then
    M.start()
  end
  panel.toggle()
end

--- Open diff for the currently selected timeline entry.
function M.show_diff()
  local entry = panel.selected()
  if not entry then
    vim.notify("[agent-lens] No entry selected", vim.log.levels.INFO)
    return
  end
  if entry.kind == "read" then
    local root = M._root or read_events.root()
    local uv = vim.uv or vim.loop
    local real_root = root and uv.fs_realpath(root)
    local file = root and uv.fs_realpath(root .. "/" .. entry.rel_path)
    if not real_root or not file or file:sub(1, #real_root + 1) ~= real_root .. "/" then
      vim.notify("[agent-lens] Read target is no longer inside the project", vim.log.levels.WARN)
      return
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if win ~= panel._win then
        vim.api.nvim_set_current_win(win)
        break
      end
    end
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    return
  end
  diff_view.open(entry)
end

--- Close all agent-lens windows.
function M.close_all()
  diff_view.close()
  panel.close()
end

--- Clear the timeline.
function M.clear()
  timeline.clear()
  if panel.is_open() then
    panel.render()
  end
  vim.notify("[agent-lens] Timeline cleared", vim.log.levels.INFO)
end

--- Setup the plugin.
---@param opts? AgentLensOpts
function M.setup(opts)
  config.setup(opts)

  -- Register user commands
  vim.api.nvim_create_user_command("AgentLens", function()
    M.toggle()
  end, { desc = "Toggle agent-lens timeline" })

  vim.api.nvim_create_user_command("AgentLensStart", function(cmd)
    M.start(cmd.args ~= "" and cmd.args or nil)
  end, { nargs = "?", desc = "Start agent-lens watcher" })

  vim.api.nvim_create_user_command("AgentLensStop", function()
    M.stop()
  end, { desc = "Stop agent-lens watcher" })

  vim.api.nvim_create_user_command("AgentLensClear", function()
    M.clear()
  end, { desc = "Clear agent-lens timeline" })

  vim.api.nvim_create_user_command("AgentLensDiff", function()
    M.show_diff()
  end, { desc = "Open diff for selected entry" })

  vim.api.nvim_create_user_command("AgentLensClose", function()
    M.close_all()
  end, { desc = "Close all agent-lens windows" })

  -- Register global keymaps
  if config.options.keymaps.toggle and config.options.keymaps.toggle ~= "" then
    vim.keymap.set("n", config.options.keymaps.toggle, function()
      M.toggle()
    end, { desc = "Toggle agent-lens" })
  end

  -- Auto-start if enabled
  if config.options.enabled then
    -- Defer start slightly to let Neovim finish initializing
    vim.defer_fn(function()
      -- Only start if we're in a git repo
      if diff_engine.git_root() then
        M.start()
      end
    end, 500)
  end

  -- Auto-reload open buffers when files change externally
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
    group = vim.api.nvim_create_augroup("AgentLensAutoRead", { clear = true }),
    callback = function()
      if vim.fn.getcmdwintype() == "" then
        vim.cmd("silent! checktime")
      end
    end,
  })
end

return M
