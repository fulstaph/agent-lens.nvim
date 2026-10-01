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
---   :AgentLensInlineToggle — Toggle read/write marks in source buffers
---   :AgentLensFollow  — Toggle live agent navigation
---   :AgentLensDiff    — Open diff for selected entry

local config = require("agent-lens.config")
local watcher = require("agent-lens.watcher")
local diff_engine = require("agent-lens.diff")
local timeline = require("agent-lens.timeline")
local panel = require("agent-lens.panel")
local diff_view = require("agent-lens.diff_view")
local read_events = require("agent-lens.read_events")
local inline = require("agent-lens.inline")
local follow = require("agent-lens.follow")
local live = require("agent-lens.live")

local status = require("agent-lens.status")
local M = {}
local generation = 0
local history_root

---@type string|nil Git root of the watched project
M._root = nil

local BINARY_EXTS = {
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

--- Handle a file change event from the watcher.
---@param rel_path string Relative path from project root
---@param events table Event flags from libuv
local function on_file_change(rel_path, events)
  if not M._root then
    return
  end

  -- Skip binary files (quick heuristic: check extension)
  local ext = rel_path:match("%.([^.]+)$")
  if ext and BINARY_EXTS[ext:lower()] then
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
  end

  -- Refresh the panel if it's open
  if panel.is_open() then
    panel.render()
  end

  -- Auto-open diff if configured
  if config.options.auto_open_diff and file_diff then
    local latest = timeline.entries[#timeline.entries]
    if latest then
      M.show_diff(latest)
    end
  end

  -- Hydrate Follow drafts before checktime can prompt about a newly created file.
  follow.file_changed(M._root, rel_path)
  vim.cmd("silent! checktime")
  inline.record_write(M._root, rel_path, not events.deleted and file_diff or nil)
end

--- Start watching the project for file changes.
---@param root? string Project root (auto-detected from git or cwd)
function M.start(root)
  root = root or config.options.watch_dir or diff_engine.git_root() or vim.fn.getcwd()
  root = vim.uv.fs_realpath(root) or root
  if history_root and history_root ~= root then
    follow.clear()
    timeline.clear()
    inline.clear()
    panel.setup(config.options.timeline)
    if panel.is_open() then
      panel.render()
    end
  end
  history_root = root
  M._root = root

  watcher.start(root, on_file_change)
  status.set("watcher", { state = watcher.is_running() and "running" or "stopped", root = root })
  if config.options.reads.enabled or follow.is_enabled() then
    read_events.start(root)
  end
  live.start(root)
  vim.notify(
    string.format("[agent-lens] Watching %s", vim.fn.fnamemodify(root, ":~")),
    vim.log.levels.INFO
  )
end

--- Stop watching.
function M.stop()
  generation = generation + 1
  live.stop()
  watcher.stop()
  read_events.stop()
  follow.stop()
  M._root = nil
  status.set("watcher", { state = "stopped" })
  vim.notify("[agent-lens] Stopped watching", vim.log.levels.INFO)
end

--- Toggle the timeline panel. Starts the watcher if not running.
function M.toggle()
  if not watcher.is_running() then
    M.start()
  end
  panel.toggle()
end

--- Toggle live navigation to the active agent location.
---@return boolean enabled
function M.toggle_follow()
  local active = follow.toggle()
  if active then
    if not watcher.is_running() then
      M.start()
    elseif not read_events.is_running() and M._root then
      read_events.start(M._root)
    end
    if M._root then
      live.start(M._root)
    end
  elseif not config.options.reads.enabled then
    read_events.stop()
  end
  if not active then
    live.stop()
  end
  vim.notify(
    "[agent-lens] Follow Agent " .. (active and "enabled" or "disabled"),
    vim.log.levels.INFO
  )
  return active
end

---@return boolean
function M.pause_follow()
  return follow.pause("manual")
end
---@return boolean
function M.resume_follow()
  if not follow.is_enabled() then
    follow.resume()
  end
  if not watcher.is_running() then
    M.start()
  elseif M._root and not read_events.is_running() then
    read_events.start(M._root)
    live.start(M._root)
  end
  return follow.resume()
end

---@param mode string
---@return boolean
function M.set_follow_window(mode)
  return follow.set_window(mode)
end

local function pause_for_review()
  if follow.state().window == "current" then
    follow.pause("review")
  end
end
local function selected_or_current(entry)
  if entry then
    return entry
  end
  if panel.is_open() then
    return panel.selected()
  end
  local root = M._root or read_events.root() or diff_engine.git_root()
  local path = vim.api.nvim_buf_get_name(0)
  local real = root and vim.uv.fs_realpath(root)
  if real and path:sub(1, #real + 1) == real .. "/" then
    return { rel_path = path:sub(#real + 2), status = "modified" }
  end
end
local function open_read(entry, root)
  local path = require("agent-lens.paths").resolve(root, entry.rel_path, false)
  if not path then
    vim.notify("[agent-lens] Read target unavailable", vim.log.levels.WARN)
    return false
  end
  local buf = vim.fn.bufadd(path)
  if not pcall(vim.fn.bufload, buf) then
    return false
  end
  local win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if
      w ~= panel._win
      and vim.api.nvim_win_get_config(w).relative == ""
      and vim.bo[b].buftype == ""
      and not vim.wo[w].diff
      and not vim.wo[w].previewwindow
      and not vim.wo[w].cursorbind
      and not vim.wo[w].scrollbind
      and not vim.wo[w].winfixbuf
      and (b == buf or not vim.bo[b].modified)
    then
      win = w
      break
    end
  end
  if not win then
    local ok, result = pcall(
      vim.api.nvim_open_win,
      buf,
      true,
      { split = "right", win = vim.api.nvim_get_current_win() }
    )
    if not ok then
      return false
    end
    win = result
  else
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_set_current_win(win)
  end
  if entry.range then
    vim.api.nvim_win_set_cursor(
      win,
      { math.max(1, math.min(entry.range.start, vim.api.nvim_buf_line_count(buf))), 0 }
    )
  end
  return true
end
--- Open a current comparison or stored successful-read range.
---@param entry? TimelineEntry
---@return boolean
function M.show_diff(entry)
  entry = selected_or_current(entry)
  if not entry then
    vim.notify("[agent-lens] No review target", vim.log.levels.INFO)
    return false
  end
  pause_for_review()
  local root = M._root or read_events.root() or diff_engine.git_root()
  if entry.kind == "read" then
    return open_read(entry, root)
  end
  return diff_view.open(entry, { root = root })
end
--- Preview the selected/current edit's first hunk, or open a read range.
---@param entry? TimelineEntry
---@return boolean
function M.preview(entry)
  entry = selected_or_current(entry)
  if not entry then
    vim.notify("[agent-lens] No preview target", vim.log.levels.INFO)
    return false
  end
  pause_for_review()
  local root = M._root or read_events.root() or diff_engine.git_root()
  if entry.kind == "read" then
    return open_read(entry, root)
  end
  return diff_view.preview(entry, { root = root })
end

--- Close all agent-lens windows.
function M.close_all()
  diff_view.close()
  panel.close()
  status.close()
end

--- Clear the timeline.
function M.clear()
  timeline.clear()
  inline.clear()
  follow.clear()
  if panel.is_open() then
    panel.render()
  end
  vim.notify("[agent-lens] Timeline cleared", vim.log.levels.INFO)
end

--- Setup the plugin.
---@param opts? AgentLensOpts
function M.setup(opts)
  generation = generation + 1
  watcher.stop()
  read_events.stop()
  M._root = nil
  status.close()
  live.stop()
  status.reset()
  config.setup(opts)
  inline.setup(config.options.inline)
  follow.setup(config.options.follow)
  panel.setup(config.options.timeline)
  panel.set_actions({
    open = M.show_diff,
    preview = M.preview,
    browse = function()
      if follow.state().window == "current" then
        follow.pause("timeline")
      end
    end,
  })
  vim.api.nvim_create_user_command("AgentLensFilter", function(cmd)
    panel.set_filter(cmd.args ~= "" and cmd.args or nil)
  end, {
    nargs = "?",
    complete = function()
      return { "all", "reads", "edits" }
    end,
    desc = "Filter retained activity",
  })

  vim.api.nvim_create_user_command(
    "AgentLensPause",
    M.pause_follow,
    { desc = "Pause Follow Agent" }
  )
  vim.api.nvim_create_user_command(
    "AgentLensResume",
    M.resume_follow,
    { desc = "Resume Follow Agent" }
  )
  if config.options.keymaps.resume and config.options.keymaps.resume ~= "" then
    vim.keymap.set(
      "n",
      config.options.keymaps.resume,
      M.resume_follow,
      { desc = "Resume Follow Agent" }
    )
  end
  vim.api.nvim_create_user_command("AgentLensFollowMode", function(cmd)
    local mode = cmd.args ~= "" and cmd.args
      or (follow.state().window == "current" and "split" or "current")
    if not M.set_follow_window(mode) then
      vim.notify("[agent-lens] Follow mode must be current or split", vim.log.levels.WARN)
    end
  end, {
    nargs = "?",
    complete = function()
      return { "current", "split" }
    end,
    desc = "Choose Follow window mode",
  })
  vim.api.nvim_create_user_command("AgentLensPreview", function()
    M.preview()
  end, { desc = "Preview a current hunk or read range" })
  -- Register user commands
  vim.api.nvim_create_user_command(
    "AgentLensStatus",
    status.open,
    { desc = "Show observed Agent Lens status" }
  )
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
  vim.api.nvim_create_user_command("AgentLensInlineToggle", function()
    local visible = inline.toggle()
    vim.notify(
      "[agent-lens] Inline activity " .. (visible and "shown" or "hidden"),
      vim.log.levels.INFO
    )
  end, { desc = "Toggle agent-lens activity in file buffers" })
  vim.api.nvim_create_user_command("AgentLensFollow", function()
    M.toggle_follow()
  end, { desc = "Toggle agent-lens Follow Agent" })

  vim.api.nvim_create_user_command("AgentLensClose", function()
    M.close_all()
  end, { desc = "Close all agent-lens windows" })

  -- Register global keymaps
  if config.options.keymaps.toggle and config.options.keymaps.toggle ~= "" then
    vim.keymap.set("n", config.options.keymaps.toggle, function()
      M.toggle()
    end, { desc = "Toggle agent-lens" })
  end
  if config.options.keymaps.follow and config.options.keymaps.follow ~= "" then
    vim.keymap.set("n", config.options.keymaps.follow, function()
      M.toggle_follow()
    end, { desc = "Toggle agent-lens Follow Agent" })
  end

  -- Auto-start if enabled
  if config.options.enabled then
    -- Defer start slightly to let Neovim finish initializing
    local epoch = generation
    vim.defer_fn(function()
      if epoch ~= generation then
        return
      end
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
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("AgentLensLiveCleanup", { clear = true }),
    callback = live.stop,
  })
end

---@return StatusSnapshot
function M.status()
  return status.get()
end
---@return string
function M.statusline()
  return status.statusline()
end

return M
