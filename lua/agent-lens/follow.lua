--- Zed-style live navigation to the active agent location.
local config = require("agent-lens.config")

local M = {}
local uv = vim.uv or vim.loop
local namespace = vim.api.nvim_create_namespace("agent_lens_follow")
local enabled = false
local target
local active_call_id
local follow_win
local mark
local warned_split = false

local function clear_mark()
  if mark and vim.api.nvim_buf_is_valid(mark.buf) then
    vim.api.nvim_buf_clear_namespace(mark.buf, namespace, 0, -1)
  end
  mark = nil
end

local function target_buffer(root, rel_path)
  local path = uv.fs_realpath(root .. "/" .. rel_path)
  if not path then
    return nil
  end
  local buf = vim.fn.bufadd(path)
  if buf < 1 or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  if not vim.api.nvim_buf_is_loaded(buf) then
    local ok = pcall(vim.fn.bufload, buf)
    if not ok or not vim.api.nvim_buf_is_loaded(buf) then
      return nil
    end
  end
  return buf
end

local function is_editor_window(win, target_buf)
  if not win or not vim.api.nvim_win_is_valid(win) then
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
  warned_split = false
  return win
end

local function select_window(buf)
  local current = vim.api.nvim_get_current_win()
  local windows = vim.api.nvim_tabpage_list_wins(0)

  for _, win in ipairs(windows) do
    if vim.api.nvim_win_get_buf(win) == buf and is_editor_window(win, buf) then
      return win
    end
  end
  if is_editor_window(follow_win, buf) then
    return follow_win
  end
  for _, win in ipairs(windows) do
    if win ~= current and is_editor_window(win, buf) then
      return win
    end
  end
  if is_editor_window(current, buf) then
    return current
  end
  return create_window(buf)
end

local function center_view(win, buf, line)
  local height = vim.api.nvim_win_get_height(win)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local max_topline = math.max(1, line_count - height + 1)
  local topline = math.max(1, math.min(max_topline, line - math.floor((height - 1) / 2)))
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = topline })
  end)
end

local function render()
  if not enabled or not target or not target.path then
    return false
  end
  local buf = target_buffer(target.root, target.path)
  if not buf then
    return false
  end
  local win = select_window(buf)
  if not win then
    return false
  end
  local ok = pcall(vim.api.nvim_win_set_buf, win, buf)
  if not ok then
    return false
  end

  local line = math.max(1, math.min(target.line or 1, vim.api.nvim_buf_line_count(buf)))
  clear_mark()
  local placed, id = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line - 1, 0, {
    line_hl_group = config.options.highlights.follow,
    virt_text = { { "  AGENT · " .. target.agent, config.options.highlights.follow_label } },
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
  follow_win = win
  center_view(win, buf, line)
  return true
end

---@param opts {enabled?: boolean}
function M.setup(opts)
  clear_mark()
  enabled = opts.enabled == true
  target = nil
  active_call_id = nil
  follow_win = nil
  warned_split = false
end

---@param root string
---@param location {call_id: string, phase: "start"|"success"|"error", tool: "read"|"edit"|"write", path?: string, line?: integer, agent: string}
function M.record_location(root, location)
  if location.phase == "start" then
    active_call_id = location.call_id
  elseif not active_call_id or location.call_id ~= active_call_id then
    return
  end

  if location.phase == "error" then
    active_call_id = nil
    target = nil
    clear_mark()
    follow_win = nil
    return
  end

  local previous = location.phase == "success" and target or nil
  target = {
    call_id = location.call_id,
    phase = location.phase,
    tool = location.tool,
    path = location.path or (previous and previous.path),
    line = location.line or (previous and previous.line),
    agent = location.agent or (previous and previous.agent),
    root = root,
    needs_refresh = location.tool ~= "read",
  }
  if location.phase == "success" then
    active_call_id = nil
  end
  render()
end

---@param root string
---@param rel_path string
function M.file_changed(root, rel_path)
  if not target or not target.needs_refresh or target.root ~= root or target.path ~= rel_path then
    return
  end
  if render() then
    target = vim.tbl_extend("force", {}, target, { needs_refresh = false })
  end
end

---@return boolean
function M.toggle()
  enabled = not enabled
  if enabled then
    render()
  else
    clear_mark()
    follow_win = nil
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
  follow_win = nil
  clear_mark()
end

return M
