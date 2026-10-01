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
local keymaps = require("agent-lens.keymaps")
local motion = require("agent-lens.motion")

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

--- Current-window Follow yields to review UI; split Follow keeps following.
---@param why string
local function yield_follow(why)
  if follow.state().window == "current" then
    follow.pause(why)
  end
end

--- Record one computed change in the timeline and editor views.
---@param root string
---@param change {rel_path: string, events: table}
---@param snapshot ReviewSnapshot|nil
local function apply_change(root, change, snapshot)
  local rel_path, events = change.rel_path, change.events
  local file_diff = snapshot and snapshot.comparison
  local entry
  if file_diff then
    entry =
      timeline.add({ rel_path = rel_path, status = file_diff.status, stats = file_diff.stats })
  elseif events.deleted then
    entry = timeline.add({ rel_path = rel_path, status = "deleted" })
  end

  if panel.is_open() then
    panel.render()
  end
  if config.options.auto_open_diff and file_diff then
    yield_follow("review")
    diff_view.open(entry, { root = root, snapshot = snapshot })
  end

  -- Hydrate Follow drafts before checktime can prompt about a newly created file.
  follow.file_changed(root, rel_path)
  vim.cmd("silent! checktime")
  inline.record_write(root, rel_path, file_diff)
end

--- Fetch review data inside the diff coroutine; rendering must not wait on Git.
---@param root string
---@param path string
---@return ReviewSnapshot|nil
local function compute_change(root, path)
  local comparison = diff_engine.review(root, path)
  if not comparison then
    return nil
  end
  local auto_open = config.options.auto_open_diff
  return {
    root = root,
    comparison = comparison,
    head = auto_open and diff_engine.head_contents(root, path) or {},
    disk = auto_open and diff_engine.working_contents(root, path) or {},
  }
end

-- Watcher changes are diffed one at a time, in arrival order, without blocking
-- the editor. A path queued again before it is processed keeps one slot.
local change_epoch = 0
local queued, queued_by_path, draining = {}, {}, false

local function reset_changes()
  change_epoch = change_epoch + 1
  queued, queued_by_path, draining = {}, {}, false
end

local function drain_changes()
  if draining or #queued == 0 or not M._root then
    return
  end
  draining = true
  local root, epoch, batch = M._root, change_epoch, queued
  queued, queued_by_path = {}, {}
  local candidates = {}
  for i, change in ipairs(batch) do
    candidates[i] = change.rel_path
  end
  diff_engine.async(diff_engine.ignored, function(ignored)
    local index = 0
    local function next_change()
      if epoch ~= change_epoch then
        return
      end
      index = index + 1
      local change = batch[index]
      if not change then
        draining = false
        return drain_changes()
      end
      if ignored and ignored[change.rel_path] then
        return next_change()
      end
      diff_engine.async(compute_change, function(snapshot)
        if epoch ~= change_epoch then
          return
        end
        local ok, err = pcall(apply_change, root, change, snapshot)
        if not ok then
          vim.notify("[agent-lens] Cannot record change: " .. tostring(err), vim.log.levels.ERROR)
        end
        next_change()
      end, root, change.rel_path)
    end
    next_change()
  end, root, candidates)
end

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

  local change = queued_by_path[rel_path]
  if change then
    change.events = events
    return
  end
  change = { rel_path = rel_path, events = events }
  queued_by_path[rel_path] = change
  queued[#queued + 1] = change
  drain_changes()
end

--- Stop every source and drop queued work from the previous root.
local function teardown()
  generation = generation + 1
  reset_changes()
  live.stop()
  watcher.stop()
  read_events.stop()
  M._root = nil
end

--- Forget retained activity in every projection.
local function reset_history()
  follow.clear()
  timeline.clear()
  inline.clear()
end

--- Start watching the project for file changes.
---@param root? string Project root (auto-detected from git or cwd)
---@return boolean started
function M.start(root)
  root = root or config.options.watch_dir or diff_engine.git_root() or vim.fn.getcwd()
  local real = type(root) == "string" and vim.uv.fs_realpath(root)
  local stat = real and vim.uv.fs_stat(real)
  if not stat or stat.type ~= "directory" then
    vim.notify("[agent-lens] Watch directory unavailable: " .. tostring(root), vim.log.levels.ERROR)
    return false
  end
  root = real
  if history_root and history_root ~= root then
    reset_history()
    panel.setup(config.options.timeline)
    if panel.is_open() then
      panel.render()
    end
  end
  history_root = root
  M._root = root
  reset_changes()

  watcher.start(root, on_file_change, {
    -- Startup scans wait for the answer; new directories ask without blocking.
    ignored_directories = function(rel_dir, done)
      if not done then
        return diff_engine.ignored_directories(root, rel_dir)
      end
      diff_engine.async(diff_engine.ignored_directories, done, root, rel_dir)
    end,
  })
  status.set("watcher", { state = watcher.is_running() and "running" or "stopped", root = root })
  if not watcher.is_running() then
    M._root = nil
    read_events.stop()
    live.stop()
    vim.notify("[agent-lens] Cannot start file watcher", vim.log.levels.ERROR)
    return false
  end
  if config.options.reads.enabled or follow.is_enabled() then
    read_events.start(root)
  end
  live.start(root)
  vim.notify(
    string.format("[agent-lens] Watching %s", vim.fn.fnamemodify(root, ":~")),
    vim.log.levels.INFO
  )
  return true
end

--- Stop watching.
function M.stop()
  teardown()
  follow.stop()
  status.set("watcher", { state = "stopped", root = history_root })
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
  if not active then
    if not config.options.reads.enabled then
      read_events.stop()
    end
    live.stop()
  elseif not watcher.is_running() then
    M.start()
  elseif M._root then
    if not read_events.is_running() then
      read_events.start(M._root)
    end
    live.start(M._root)
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
  local enabling = not follow.is_enabled()
  if enabling then
    follow.resume()
  end
  if not watcher.is_running() then
    M.start()
  elseif M._root then
    if not read_events.is_running() then
      read_events.start(M._root)
    end
    if enabling then
      live.start(M._root)
    end
  end
  return follow.resume()
end

---@param mode string
---@return boolean
function M.set_follow_window(mode)
  return follow.set_window(mode)
end

local function review_root()
  return M._root or read_events.root() or history_root or diff_engine.git_root()
end
local function selected_or_current(entry, root)
  if entry then
    return entry
  end
  if panel.is_open() then
    return panel.selected()
  end
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
      and motion.plain_window(w)
      and vim.bo[b].buftype == ""
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
local function open_entry(entry, method, missing_message)
  -- One lookup: without a watched root this spawns Git, so it is not repeated.
  local root = review_root()
  entry = selected_or_current(entry, root)
  if not entry then
    vim.notify("[agent-lens] " .. missing_message, vim.log.levels.INFO)
    return false
  end
  yield_follow("review")
  if entry.kind == "read" then
    return open_read(entry, root)
  end
  return diff_view[method](entry, { root = root })
end
--- Open a current comparison or stored successful-read range.
---@param entry? TimelineEntry
---@return boolean
function M.show_diff(entry)
  return open_entry(entry, "open", "No review target")
end
--- Preview the selected/current edit's first hunk, or open a read range.
---@param entry? TimelineEntry
---@return boolean
function M.preview(entry)
  return open_entry(entry, "preview", "No preview target")
end

--- Close all agent-lens windows.
function M.close_all()
  diff_view.close()
  panel.close()
  status.close()
end

--- Clear the timeline.
function M.clear()
  reset_history()
  if panel.is_open() then
    panel.render()
  end
  vim.notify("[agent-lens] Timeline cleared", vim.log.levels.INFO)
end

local function register_action_command(name, method, description)
  vim.api.nvim_create_user_command(name, function()
    M[method]()
  end, { desc = description })
end

local function register_keymap(option, method, description)
  keymaps.set(config.options.keymaps[option], function()
    M[method]()
  end, { desc = description })
end

--- Setup the plugin.
---@param opts? AgentLensOpts
function M.setup(opts)
  teardown()
  status.close()
  status.reset()
  status.set("watcher", { state = "stopped", root = history_root })
  keymaps.clear()
  config.setup(opts)
  inline.setup(config.options.inline)
  follow.setup(config.options.follow)
  panel.setup(config.options.timeline)
  panel.set_actions({
    open = M.show_diff,
    preview = M.preview,
    browse = function()
      yield_follow("timeline")
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

  register_action_command("AgentLensPause", "pause_follow", "Pause Follow Agent")
  register_action_command("AgentLensResume", "resume_follow", "Resume Follow Agent")
  register_keymap("resume", "resume_follow", "Resume Follow Agent")
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
  register_action_command("AgentLensPreview", "preview", "Preview a current hunk or read range")
  -- Register user commands
  vim.api.nvim_create_user_command(
    "AgentLensStatus",
    status.open,
    { desc = "Show observed Agent Lens status" }
  )
  register_action_command("AgentLens", "toggle", "Toggle agent-lens timeline")

  vim.api.nvim_create_user_command("AgentLensStart", function(cmd)
    M.start(cmd.args ~= "" and cmd.args or nil)
  end, { nargs = "?", desc = "Start agent-lens watcher" })

  register_action_command("AgentLensStop", "stop", "Stop agent-lens watcher")
  register_action_command("AgentLensClear", "clear", "Clear agent-lens timeline")
  register_action_command("AgentLensDiff", "show_diff", "Open diff for selected entry")
  vim.api.nvim_create_user_command("AgentLensInlineToggle", function()
    local visible = inline.toggle()
    vim.notify(
      "[agent-lens] Inline activity " .. (visible and "shown" or "hidden"),
      vim.log.levels.INFO
    )
  end, { desc = "Toggle agent-lens activity in file buffers" })
  register_action_command("AgentLensFollow", "toggle_follow", "Toggle agent-lens Follow Agent")
  register_action_command("AgentLensClose", "close_all", "Close all agent-lens windows")

  register_keymap("toggle", "toggle", "Toggle agent-lens")
  register_keymap("follow", "toggle_follow", "Toggle agent-lens Follow Agent")

  -- Auto-start if enabled
  if config.options.enabled then
    -- Defer start slightly to let Neovim finish initializing
    local epoch = generation
    vim.defer_fn(function()
      if epoch ~= generation then
        return
      end
      -- Only start if we're in a git repo
      local root = diff_engine.git_root()
      if root then
        M.start(config.options.watch_dir or root)
      end
    end, 500)
  end

  -- Auto-reload open buffers when files change externally while watching
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
    group = vim.api.nvim_create_augroup("AgentLensAutoRead", { clear = true }),
    callback = function()
      if watcher.is_running() and vim.fn.getcmdwintype() == "" then
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
