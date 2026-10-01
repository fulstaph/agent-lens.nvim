--- Bounded presentation animation for transient drafts, using Neovim builtins.
local config = require("agent-lens.config")
local uv = vim.uv
local M = {}
local drafts = {}
local views = {}
local timer
local generation = 0
local scheduled = false
local tokens = { frame_ms = 16, scroll_ms = 120, max_bytes = 65536 }

local function now()
  return uv.hrtime() / 1000000
end

local function duration()
  local opts = config.options.follow or {}
  if opts.animation == false then
    return 0
  end
  return math.max(0, math.min(400, tonumber(opts.animation_ms) or 180))
end

local function stop_timer()
  generation = generation + 1
  scheduled = false
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function span(before, after)
  local first = 1
  while first <= #before and first <= #after and before[first] == after[first] do
    first = first + 1
  end
  local old_end, new_end = #before, #after
  while old_end >= first and new_end >= first and before[old_end] == after[new_end] do
    old_end, new_end = old_end - 1, new_end - 1
  end
  return first, old_end, new_end
end

local function slice(lines, first, last)
  local result = {}
  for index = first, last do
    result[#result + 1] = lines[index]
  end
  return result
end

local function apply(buf, lines)
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local first, old_end, new_end = span(before, lines)
  if first > old_end and first > new_end then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, first - 1, old_end, false, slice(lines, first, new_end))
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
end

local function utf8_boundary(text, offset)
  while offset > 0 do
    local byte = text:byte(offset + 1)
    if not byte or byte < 128 or byte >= 192 then
      break
    end
    offset = offset - 1
  end
  return offset
end

local function position(text, first)
  local _, count = text:gsub("\n", "")
  return first + count, #(text:match("[^\n]*$") or "")
end

local function safe_view(win, buf)
  return vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_win_get_buf(win) == buf
    and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
    and vim.api.nvim_win_get_config(win).relative == ""
    and not vim.wo[win].diff
    and not vim.wo[win].previewwindow
    and not vim.wo[win].cursorbind
    and not vim.wo[win].scrollbind
end

local function paint_view(win, state, progress)
  if not safe_view(win, state.buf) then
    views[win] = nil
    return
  end
  local eased = 1 - (1 - progress) ^ 3
  local row = math.floor(state.from_row + (state.row - state.from_row) * eased + 0.5)
  local top = math.floor(state.from_top + (state.top - state.from_top) * eased + 0.5)
  row = math.max(1, math.min(row, vim.api.nvim_buf_line_count(state.buf)))
  local text = vim.api.nvim_buf_get_lines(state.buf, row - 1, row, false)[1] or ""
  local col = row == state.row and math.min(state.col, #text) or 0
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_cursor(win, { row, col })
    if vim.fn.foldclosed(row) ~= -1 then
      vim.cmd(row .. "foldopen!")
    end
    vim.fn.winrestview({ topline = math.max(1, top) })
  end)
  if progress == 1 then
    views[win] = nil
  end
end

local function paint_draft(buf, state, progress)
  if not vim.api.nvim_buf_is_valid(buf) then
    drafts[buf] = nil
    return
  end
  local revealed = utf8_boundary(state.added, math.ceil(#state.added * progress))
  local caret = state.prefix .. state.added:sub(1, revealed)
  local lines
  if progress == 1 then
    lines = state.lines
    drafts[buf] = nil
  else
    local body = vim.split(caret .. state.suffix, "\n", { plain = true })
    lines = slice(state.before, 1, state.first - 1)
    vim.list_extend(lines, body)
    vim.list_extend(lines, slice(state.before, state.old_end + 1, #state.before))
  end
  apply(buf, lines)
  local row, col = position(caret, state.first)
  row = math.max(1, math.min(row, #lines))
  state.frame(row, col, progress == 1)
end

local function tick()
  local time = now()
  for buf, state in pairs(drafts) do
    local elapsed = (time - state.started) / math.max(1, state.deadline - state.started)
    paint_draft(buf, state, math.max(0, math.min(1, elapsed)))
  end
  for win, state in pairs(views) do
    local elapsed = (time - state.started) / math.max(1, state.deadline - state.started)
    paint_view(win, state, math.max(0, math.min(1, elapsed)))
  end
  if not next(drafts) and not next(views) then
    stop_timer()
  end
end

local function start_timer()
  if timer then
    return
  end
  timer = uv.new_timer()
  if not timer then
    for buf, state in pairs(drafts) do
      paint_draft(buf, state, 1)
    end
    return
  end
  local epoch = generation
  timer:start(tokens.frame_ms, tokens.frame_ms, function()
    if scheduled or epoch ~= generation then
      return
    end
    scheduled = true
    vim.schedule(function()
      if epoch ~= generation then
        return
      end
      scheduled = false
      tick()
    end)
  end)
end

--- Reveal the changed span, retaining untouched source context and UTF-8 boundaries.
---@param buf integer Read-only draft buffer
---@param lines string[] Latest complete snapshot
---@param line integer Fallback caret row when the text is unchanged
---@param frame fun(row: integer, col: integer, done: boolean)
function M.reveal(buf, lines, line, frame)
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local first, old_end, new_end = span(before, lines)
  if first > old_end and first > new_end then
    drafts[buf] = nil
    line = math.max(1, math.min(line, #lines))
    frame(line, #lines[line], true)
    return
  end
  local old = table.concat(slice(before, first, old_end), "\n")
  local new = table.concat(slice(lines, first, new_end), "\n")
  local common = 0
  while common < #old and common < #new and old:byte(common + 1) == new:byte(common + 1) do
    common = common + 1
  end
  common = utf8_boundary(new, common)
  local tail = 0
  while
    tail < #old - common
    and tail < #new - common
    and old:byte(#old - tail) == new:byte(#new - tail)
  do
    tail = tail + 1
  end
  while tail > 0 and utf8_boundary(new, #new - tail) ~= #new - tail do
    tail = tail - 1
  end
  local time = now()
  local previous = drafts[buf]
  local state = {
    before = before,
    lines = lines,
    first = first,
    old_end = old_end,
    prefix = new:sub(1, common),
    added = new:sub(common + 1, #new - tail),
    suffix = tail > 0 and new:sub(#new - tail + 1) or "",
    started = time,
    deadline = previous and previous.deadline or time + duration(),
    frame = frame,
  }
  if duration() == 0 or #state.added == 0 or #new > tokens.max_bytes or state.deadline <= time then
    paint_draft(buf, state, 1)
  else
    drafts[buf] = state
    paint_draft(buf, state, 0)
    start_timer()
  end
end

--- Ease the followed viewport, keeping it still while the caret is comfortably visible.
---@param win integer
---@param buf integer
---@param row integer
---@param col integer
function M.view(win, buf, row, col)
  if not safe_view(win, buf) then
    return
  end
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local height = vim.api.nvim_win_get_height(win)
  local padding = math.min(4, math.floor(height / 4))
  local top = view.topline
  if row < top + padding or row > top + height - padding - 1 then
    local count = vim.api.nvim_buf_line_count(buf)
    top = math.max(1, math.min(count - height + 1, row - math.floor(height / 2)))
  end
  local previous = views[win]
  local time = now()
  local state = {
    buf = buf,
    from_row = view.lnum,
    from_top = view.topline,
    row = row,
    col = col,
    top = top,
    started = time,
    deadline = previous and previous.deadline or time + math.min(duration(), tokens.scroll_ms),
  }
  if top == view.topline or duration() == 0 or state.deadline <= time then
    views[win] = nil
    paint_view(win, state, 1)
  else
    views[win] = state
    start_timer()
  end
end

--- Whether a draft is still catching up with its latest snapshot.
---@param buf integer
---@return boolean
function M.is_revealing(buf)
  return drafts[buf] ~= nil
end

--- Cancel motion when its draft is removed; queued frames cannot resurrect it.
---@param buf? integer Omit to stop all motion
function M.stop(buf)
  if buf then
    drafts[buf] = nil
    for win, state in pairs(views) do
      if state.buf == buf then
        views[win] = nil
      end
    end
  else
    drafts = {}
    views = {}
  end
  if not next(drafts) and not next(views) then
    stop_timer()
  end
end

return M
