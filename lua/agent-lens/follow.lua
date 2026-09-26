--- Zed-style live navigation to the active agent location.
local config = require("agent-lens.config")

local M = {}
local uv = vim.uv or vim.loop
local namespace = vim.api.nvim_create_namespace("agent_lens_follow")
local enabled = false
local target
local active_call_id
local mark
local warned_split = false

local function clear_mark()
  if mark and vim.api.nvim_buf_is_valid(mark.buf) then
    vim.api.nvim_buf_clear_namespace(mark.buf, namespace, 0, -1)
  end
  mark = nil
end

local function relative_path(path)
  if type(path) ~= "string" or path == "" or path:find("[%z\1-\31]") or path:sub(1, 1) == "/" then
    return false
  end
  for part in path:gmatch("[^/]+") do
    if part == "." or part == ".." then
      return false
    end
  end
  return path ~= ".git" and path:sub(1, 5) ~= ".git/"
end

local function inside(root, path)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end
local function has_symlink_component(root, candidate)
  local relative = candidate:sub(#root + 2)
  local component = root
  for part in relative:gmatch("[^/]+") do
    component = component .. "/" .. part
    local stat = uv.fs_lstat(component)
    if stat and stat.type == "link" then
      return true
    end
    if not stat then
      return false
    end
  end
  return false
end
--- Resolve and validate a workspace-relative file target.
---@param root string Workspace root path
---@param rel_path string Relative file path
---@param allow_missing? boolean Whether to allow non-existent leaf targets
---@return string|nil resolved Absolute path or nil if invalid/unsafe
function M.target_path(root, rel_path, allow_missing)
  if not relative_path(rel_path) then
    return nil
  end
  local candidate = root .. "/" .. rel_path
  local real_root = uv.fs_realpath(root)
  if not real_root or has_symlink_component(root, candidate) then
    return nil
  end
  local resolved = uv.fs_realpath(candidate)
  if resolved then
    local stat = uv.fs_stat(resolved)
    return stat and stat.type == "file" and inside(real_root, resolved) and resolved or nil
  end
  if not allow_missing or uv.fs_lstat(candidate) then
    return nil
  end

  local ancestor = candidate
  while true do
    local real_ancestor = uv.fs_realpath(ancestor)
    if real_ancestor then
      return inside(real_root, real_ancestor) and candidate or nil
    end
    local parent = vim.fn.fnamemodify(ancestor, ":h")
    if parent == ancestor then
      return nil
    end
    ancestor = parent
  end
end
local target_path = M.target_path

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
  if
    vim.bo[buf].buftype ~= ""
    or name:match("^agent%-lens://")
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
  if not enabled or not target or not target.path then
    return false
  end
  clear_mark()
  local buf = target_buffer(target.root, target.path, target.tool == "edit")
  if not buf then
    return false
  end
  local win = select_window(buf)
  if not win then
    return false
  end
  local ok = pcall(vim.api.nvim_win_set_buf, win, buf)
  if not ok then
    win = create_window(buf)
    if not win then
      return false
    end
  end

  local line = math.max(1, math.min(target.line or 1, vim.api.nvim_buf_line_count(buf)))
  local placed, id = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line - 1, 0, {
    line_hl_group = config.options.highlights.follow,
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
  center_view(win, line)
  return true
end

---@param opts {enabled?: boolean}
function M.setup(opts)
  clear_mark()
  enabled = opts.enabled == true
  target = nil
  active_call_id = nil
  warned_split = false
end

---@param root string
---@param location {call_id: string, phase: "start"|"progress"|"success"|"error", tool: "read"|"edit"|"write", path?: string, line?: integer, agent: string, sequence?: integer}
function M.record_location(root, location)
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

  if not active_call_id or location.call_id ~= active_call_id then
    return
  end
  if location.phase == "error" then
    active_call_id = nil
    target = nil
    clear_mark()
    return
  end

  local previous = target
  target = {
    call_id = location.call_id,
    phase = "success",
    tool = location.tool,
    path = location.path or (previous and previous.path),
    line = location.line or (previous and previous.line),
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
    clear_mark()
  end
  return enabled
end

---@return boolean
function M.is_enabled()
  return enabled
end

function M.clear()
  target = nil
  active_call_id = nil
  clear_mark()
end

return M
