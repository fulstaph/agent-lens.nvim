--- Zed-style live navigation to the active agent location.
local config = require("agent-lens.config")
local status = require("agent-lens.status")
local motion = require("agent-lens.motion")

local M = {}
local uv = vim.uv
local namespace = vim.api.nvim_create_namespace("agent_lens_follow")
local caret_namespace = vim.api.nvim_create_namespace("agent_lens_caret")
local change_namespace = vim.api.nvim_create_namespace("agent_lens_draft_change")
local enabled = false
local target
local active_call_id
local mark
local warned_split = false
local preview
local finished_calls = {}
local finished_order = {}

local function clear_mark()
  if mark and vim.api.nvim_buf_is_valid(mark.buf) then
    vim.api.nvim_buf_clear_namespace(mark.buf, namespace, 0, -1)
    vim.api.nvim_buf_clear_namespace(mark.buf, caret_namespace, 0, -1)
  end
  mark = nil
end

--- Resolve a repository-relative file without crossing links or repository boundaries.
---@param root string
---@param rel_path string
---@param allow_missing? boolean
---@return string|nil
function M.target_path(root, rel_path, allow_missing)
  return require("agent-lens.paths").resolve(root, rel_path, allow_missing)
end
local target_path = M.target_path

local function publish()
  status.set("follow", { control = enabled and "following" or "off", window = "current" })
  local phases =
    { progress = "drafting", success = "settled", error = "failed", start = "applying" }
  status.set("activity", target and {
    phase = target.tool == "read" and target.phase == "start" and "reading" or phases[target.phase],
    tool = target.tool,
    path = target.path,
    line = target.line,
    call_id = target.call_id,
  } or { phase = "idle" })
end

local function file_version(path)
  local stat = uv.fs_stat(path)
  if not stat then
    return "missing"
  end
  return table.concat({
    stat.dev,
    stat.ino,
    stat.size,
    stat.mtime.sec,
    stat.mtime.nsec,
    stat.ctime.sec,
    stat.ctime.nsec,
  }, ":")
end

local function load_buffer(buf, path)
  local state = vim.b[buf].agent_lens_follow_load or {}
  if vim.bo[buf].modified then
    if state.version == "missing" and uv.fs_stat(path) and not state.warned_conflict then
      vim.b[buf].agent_lens_follow_load = vim.tbl_extend("force", {}, state, {
        warned_conflict = true,
      })
      vim.notify(
        "[agent-lens] File appeared on disk; keeping unsaved Follow buffer: "
          .. vim.fn.fnamemodify(path, ":t"),
        vim.log.levels.WARN
      )
    end
    return true
  end
  local loaded = vim.api.nvim_buf_is_loaded(buf)
  local version = file_version(path)
  if version == "missing" and loaded then
    return state.version == "missing" and not state.error
  end
  if loaded and not state.error and state.version == version then
    return true
  end

  local ok, err = pcall(function()
    if loaded then
      -- A loaded buffer can still be an empty draft or a failed BufReadCmd.
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent keepalt keepjumps edit")
      end)
    else
      vim.fn.bufload(buf)
    end
  end)
  if not ok or not vim.api.nvim_buf_is_loaded(buf) then
    local reason = tostring(err or "buffer did not load")
    vim.b[buf].agent_lens_follow_load = { error = reason }
    if state.error ~= reason then
      vim.notify(
        "[agent-lens] Cannot load Follow target " .. path .. ": " .. reason,
        vim.log.levels.ERROR
      )
    end
    return false
  end
  vim.b[buf].agent_lens_follow_load = { version = version }
  return true
end

local function target_buffer(root, rel_path, allow_missing)
  local path = target_path(root, rel_path, allow_missing)
  if not path then
    return nil
  end
  local buf = vim.fn.bufnr(path)
  if buf < 0 and allow_missing and not uv.fs_stat(path) then
    -- A named, loaded buffer avoids Neovim's W13 prompt if the file later appears.
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, path)
    vim.b[buf].agent_lens_follow_load = { version = "missing" }
  elseif buf < 0 then
    buf = vim.fn.bufadd(path)
  end
  if buf < 1 or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  if not load_buffer(buf, path) then
    return nil
  end
  return buf
end

local function clear_preview()
  if not preview then
    return
  end
  local previous = preview
  preview = nil
  motion.stop(previous.buf)
  clear_mark()
  if not vim.api.nvim_buf_is_valid(previous.buf) then
    return
  end
  local source = target_buffer(previous.root, previous.path, true)
  if source then
    for _, win in ipairs(vim.fn.win_findbuf(previous.buf)) do
      pcall(vim.api.nvim_win_set_buf, win, source)
    end
  end
  pcall(vim.api.nvim_buf_delete, previous.buf, { force = true })
end

local function finish_call(id)
  if finished_calls[id] then
    return
  end
  finished_calls[id] = true
  finished_order[#finished_order + 1] = id
  if #finished_order > 256 then
    finished_calls[table.remove(finished_order, 1)] = nil
  end
end

local function preview_baseline(root, path)
  local resolved = target_path(root, path, true)
  local stat = resolved and uv.fs_stat(resolved)
  if not stat or stat.size > 1024 * 1024 then
    return { "" }
  end
  local ok, lines = pcall(vim.fn.readfile, resolved, "", 20001)
  if not ok or #lines == 0 or #lines > 20000 then
    return { "" }
  end
  for _, line in ipairs(lines) do
    if line:find("[%z\n]") then
      return { "" }
    end
  end
  return lines
end

local function is_editor_window(win, target_buf)
  if
    not win
    or not vim.api.nvim_win_is_valid(win)
    or vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage()
  then
    return false
  end
  local ok, window_config = pcall(vim.api.nvim_win_get_config, win)
  if not ok or window_config.relative ~= "" then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local name = vim.api.nvim_buf_get_name(buf)
  local draft = vim.b[buf].agent_lens_preview == true
  if
    (vim.bo[buf].buftype ~= "" and not draft)
    or (name:match("^agent%-lens://") and not draft)
    or vim.wo[win].diff
    or vim.wo[win].previewwindow
    or vim.wo[win].cursorbind
    or vim.wo[win].scrollbind
    or (vim.wo[win].winfixbuf and buf ~= target_buf)
  then
    return false
  end
  return buf == target_buf or not vim.bo[buf].modified
end

local function create_window(buf)
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    split = "right",
    win = vim.api.nvim_get_current_win(),
  })
  if not ok or not win then
    if not warned_split then
      warned_split = true
      vim.notify("[agent-lens] Cannot open a safe window for Follow Agent", vim.log.levels.WARN)
    end
    return nil
  end
  vim.wo[win].diff = false
  vim.wo[win].previewwindow = false
  vim.wo[win].winfixwidth = false
  vim.wo[win].winfixbuf = false
  vim.wo[win].cursorbind = false
  vim.wo[win].scrollbind = false
  warned_split = false
  return win
end

local function select_window(buf)
  local current = vim.api.nvim_get_current_win()
  if is_editor_window(current, buf) then
    return current
  end

  local fallback
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_editor_window(win, buf) then
      if vim.api.nvim_win_get_buf(win) == buf then
        return win
      end
      fallback = fallback or win
    end
  end
  return fallback or create_window(buf)
end

local function center_view(win, line)
  vim.api.nvim_win_call(win, function()
    -- Redraw keeps the cursor visible; move it with the followed line.
    vim.api.nvim_win_set_cursor(win, { line, 0 })
    if vim.fn.foldclosed(line) ~= -1 then
      vim.cmd(line .. "foldopen!")
    end
    local height = vim.api.nvim_win_get_height(win)
    local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    local topline = math.max(1, math.min(count - height + 1, line - math.floor((height - 1) / 2)))
    vim.fn.winrestview({ topline = topline })
  end)
end
local function label_for(current)
  local agent = current.agent or config.options.agent_name
  if current.phase == "progress" then
    return "  AGENT · " .. agent .. " · drafting"
  end
  if current.phase == "start" then
    return "  AGENT · " .. agent .. " · applying"
  end
  return "  AGENT · " .. agent
end

local function render()
  publish()
  if not enabled or not target or not target.path then
    return false
  end
  clear_mark()
  local drafting = preview
    and preview.call_id == target.call_id
    and preview.path == target.path
    and preview.root == target.root
    and (target.phase == "progress" or target.phase == "start" or preview.settled)
  local buf = drafting and preview.buf
    or target_buffer(target.root, target.path, target.tool == "edit")
  if not buf then
    return false
  end
  local win = select_window(buf)
  if not win then
    return false
  end
  local ok = vim.api.nvim_win_get_buf(win) == buf or pcall(vim.api.nvim_win_set_buf, win, buf)
  if not ok then
    win = create_window(buf)
    if not win then
      return false
    end
  end

  local requested_line = drafting and preview.line or target.line
  local line = math.max(1, math.min(requested_line or 1, vim.api.nvim_buf_line_count(buf)))
  local placed, id = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line - 1, 0, {
    line_hl_group = drafting and config.options.highlights.added
      or config.options.highlights.follow,
    virt_text = { { label_for(target), config.options.highlights.follow_label } },
    virt_text_pos = "eol",
    hl_mode = "combine",
    priority = 200,
    right_gravity = false,
    undo_restore = false,
    invalidate = true,
  })
  if not placed then
    return false
  end
  mark = { buf = buf, id = id }
  if drafting then
    local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
    local col = math.min(preview.column or #text, #text)
    vim.api.nvim_buf_set_extmark(buf, caret_namespace, line - 1, col, {
      virt_text = { { "▏", config.options.highlights.follow_cursor } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = 250,
    })
    motion.view(win, buf, line, col)
  else
    center_view(win, line)
  end
  return true
end

---@param opts {enabled?: boolean, preview?: boolean, animation?: boolean, animation_ms?: integer}
function M.setup(opts)
  motion.stop()
  clear_preview()
  clear_mark()
  enabled = opts.enabled == true
  target = nil
  active_call_id = nil
  warned_split = false
  finished_calls = {}
  finished_order = {}
  publish()
end

--- Display a validated in-memory draft without editing source buffers or disk.
---@param root string
---@param event {toolCallId: string, tool: "edit"|"write", path: string, line: integer, sequence: integer, agent: string, lines: string[]}
---@return boolean accepted
function M.record_preview(root, event)
  if
    not enabled
    or config.options.follow.preview == false
    or finished_calls[event.toolCallId]
    or not target_path(root, event.path, true)
    or (target and target.phase == "start" and target.call_id ~= event.toolCallId)
  then
    return false
  end
  if preview and preview.call_id == event.toolCallId and event.sequence <= preview.sequence then
    return false
  end
  if
    preview
    and (preview.call_id ~= event.toolCallId or preview.path ~= event.path or preview.root ~= root)
  then
    clear_preview()
  end
  if not preview or not vim.api.nvim_buf_is_valid(preview.buf) then
    -- Seed from bounded disk contents, keeping unsaved source buffers independent.
    local baseline = preview_baseline(root, event.path)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "agent-lens://draft/" .. event.path)
    vim.b[buf].agent_lens_preview = true
    vim.bo[buf].swapfile = false
    vim.bo[buf].modeline = false
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].undolevels = -1
    vim.bo[buf].filetype = vim.filetype.match({ filename = root .. "/" .. event.path }) or ""
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, baseline)
    vim.bo[buf].modified = false
    vim.bo[buf].modifiable = false
    preview = { buf = buf, root = root, path = event.path, call_id = event.toolCallId }
  end
  preview.sequence = event.sequence
  active_call_id = event.toolCallId
  local applying = target and target.call_id == event.toolCallId and target.phase == "start"
  target = {
    call_id = event.toolCallId,
    phase = applying and "start" or "progress",
    tool = event.tool,
    path = event.path,
    line = event.line,
    agent = event.agent,
    root = root,
  }
  local buf = preview.buf
  motion.reveal(buf, event.lines, event.line, function(row, col, done)
    if not preview or preview.buf ~= buf then
      return
    end
    preview.line = row
    preview.column = col
    vim.api.nvim_buf_clear_namespace(buf, change_namespace, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, change_namespace, row - 1, 0, {
      line_hl_group = config.options.highlights.added,
      priority = 150,
    })
    if done and preview.settled then
      target.line = row
      clear_preview()
    end
    render()
  end)
  return true
end

--- Drop the active draft when its content connection closes.
---@param root string
---@param call_id string
function M.preview_disconnected(root, call_id)
  if preview and preview.root == root and preview.call_id == call_id then
    if preview.settled then
      -- A completed host turn may close its socket while the final reveal finishes.
      return
    end
    clear_preview()
    if target and target.call_id == call_id and target.phase == "progress" then
      target = nil
      active_call_id = nil
    else
      render()
    end
  end
end

---@param root string
---@param location {call_id: string, phase: "start"|"progress"|"success"|"error", tool: "read"|"edit"|"write", path?: string, line?: integer, agent: string, sequence?: integer}
function M.record_location(root, location)
  if finished_calls[location.call_id] then
    return
  end
  if location.phase == "progress" then
    if target and target.phase == "start" then
      return
    end
    if
      target
      and target.phase == "progress"
      and target.call_id == location.call_id
      and target.sequence
      and location.sequence <= target.sequence
    then
      return
    end
    active_call_id = location.call_id
    if preview and preview.call_id ~= location.call_id then
      clear_preview()
    end
    target = {
      call_id = location.call_id,
      phase = "progress",
      tool = location.tool,
      path = location.path,
      line = location.line,
      agent = location.agent,
      root = root,
      sequence = location.sequence,
    }
    render()
    return
  end

  if location.phase == "start" then
    if preview and preview.call_id ~= location.call_id then
      clear_preview()
    end
    local speculative = target and target.phase == "progress" and target.call_id == location.call_id
    local same_path = speculative and target.path == location.path
    active_call_id = location.call_id
    target = {
      call_id = location.call_id,
      phase = "start",
      tool = location.tool,
      path = location.path,
      line = location.line or (same_path and target.line),
      agent = location.agent or (speculative and target.agent),
      root = root,
    }
    render()
    return
  end

  finish_call(location.call_id)
  if not active_call_id or location.call_id ~= active_call_id then
    return
  end
  if location.phase == "error" then
    clear_preview()
    active_call_id = nil
    target = nil
    clear_mark()
    status.set("activity", { phase = "failed", tool = location.tool, call_id = location.call_id })
    return
  end

  local previous = target
  local same_preview = preview
    and preview.call_id == location.call_id
    and preview.path == (location.path or (previous and previous.path))
  local catching_up = same_preview and motion.is_revealing(preview.buf)
  local last_line = same_preview and preview.line
  if catching_up then
    preview.settled = true
  else
    clear_preview()
  end
  target = {
    call_id = location.call_id,
    phase = "success",
    tool = location.tool,
    path = location.path or (previous and previous.path),
    line = last_line or location.line or (previous and previous.line),
    agent = location.agent or (previous and previous.agent),
    root = root,
  }
  active_call_id = nil
  render()
end

---@param root string
---@param rel_path string
function M.file_changed(root, rel_path)
  if not target or target.root ~= root or target.path ~= rel_path then
    return
  end
  render()
end

---@return boolean
function M.toggle()
  enabled = not enabled
  if enabled then
    render()
  else
    clear_preview()
    clear_mark()
  end
  publish()
  return enabled
end

---@return boolean
function M.is_enabled()
  publish()
  return enabled
end

function M.clear()
  motion.stop()
  clear_preview()
  target = nil
  active_call_id = nil
  clear_mark()
  finished_calls = {}
  finished_order = {}
  publish()
end

return M
