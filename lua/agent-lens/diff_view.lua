--- Owned current-comparison windows. Original tabs and user buffers survive review.
local config = require("agent-lens.config")
local diff = require("agent-lens.diff")
local M = {}
---@class ReviewOrigin
---@field tab integer
---@field win integer
---@field buf integer
---@field view table
local session
local serial = 0
local guard = false
local ns = vim.api.nvim_create_namespace("agent_lens_review")
local function notify(message)
  vim.notify("[agent-lens] " .. message, vim.log.levels.INFO)
end
local function origin()
  return {
    tab = vim.api.nvim_get_current_tabpage(),
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
    view = vim.fn.winsaveview(),
  }
end
local function return_to(o)
  if o and vim.api.nvim_win_is_valid(o.win) then
    vim.api.nvim_set_current_win(o.win)
    if vim.api.nvim_win_get_buf(o.win) == o.buf then
      vim.fn.winrestview(o.view)
    end
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative == "" and vim.bo[buf].buftype == "" then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
end
local function owned(w)
  return vim.api.nvim_win_is_valid(w.win)
    and vim.api.nvim_win_get_buf(w.win) == w.buf
    and not vim.bo[w.buf].modified
end
local function cleanup_buffers(s)
  for _, buf in ipairs(s.buffers) do
    if
      vim.api.nvim_buf_is_valid(buf)
      and not vim.bo[buf].modified
      and #vim.fn.win_findbuf(buf) == 0
    then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end
--- Close owned windows individually, retaining reused/user windows and buffers.
---@param restore? boolean
function M.close(restore)
  if not session then
    return
  end
  local s = session
  session = nil
  guard = true
  for i = #s.windows, 1, -1 do
    local w = s.windows[i]
    if owned(w) and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, w.win, true)
    end
  end
  cleanup_buffers(s)
  if restore ~= false then
    return_to(s.origin)
  end
  guard = false
end
local function scratch(s, side, contents)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "agent-lens://review/" .. s.id .. "/" .. side .. "/" .. s.path)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modeline = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = vim.filetype.match({ filename = s.path }) or ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, contents)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  s.buffers[#s.buffers + 1] = buf
  return buf
end
local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end
local function keys(buf, preview)
  local function map(k, fn)
    vim.keymap.set("n", k, fn, { buffer = buf, silent = true, nowait = true })
  end
  map("q", M.close)
  map("<Esc>", M.close)
  map("R", M.refresh)
  map("]h", function()
    M.navigate_hunk(1)
  end)
  map("[h", function()
    M.navigate_hunk(-1)
  end)
  if preview then
    map("<CR>", function()
      if session then
        M.open({ rel_path = session.path }, { root = session.root })
      end
    end)
  else
    map("]f", function()
      M.navigate_file(1)
    end)
    map("[f", function()
      M.navigate_file(-1)
    end)
  end
end
local function hunk_position()
  local s = session
  local h = s.fd and s.fd.hunks[s.hunk]
  if not h then
    return
  end
  for i, w in ipairs(s.windows) do
    if owned(w) then
      local row = math.max(
        1,
        math.min(i == 1 and h.old_start or h.new_start, vim.api.nvim_buf_line_count(w.buf))
      )
      vim.api.nvim_win_call(w.win, function()
        vim.api.nvim_win_set_cursor(w.win, { row, 0 })
        vim.cmd("normal! zz")
      end)
    end
  end
end
local function draw()
  local s = session
  if not s then
    return
  end
  local count = s.fd and #s.fd.hunks or 0
  s.hunk = math.max(1, math.min(s.hunk, math.max(1, count)))
  local label = s.path .. " · HEAD → disk · hunk " .. s.hunk .. "/" .. count
  if s.mode == "preview" then
    local w = s.windows[1]
    if not owned(w) then
      return
    end
    local lines = { label, "" }
    local h = s.fd and s.fd.hunks[s.hunk]
    if h then
      lines[#lines + 1] = h.header
      vim.list_extend(lines, h.lines)
    else
      lines[#lines + 1] = s.error or "No current text changes"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "]h/[h hunks · R refresh · CR full · q close"
    set_lines(w.buf, lines)
    vim.api.nvim_buf_clear_namespace(w.buf, ns, 0, -1)
    vim.api.nvim_buf_add_highlight(w.buf, ns, config.options.highlights.header, 0, 0, -1)
    for i, line in ipairs(lines) do
      local c = line:sub(1, 1)
      local hl = c == "+" and config.options.highlights.added
        or c == "-" and config.options.highlights.removed
        or c == "@" and config.options.highlights.header
      if hl then
        vim.api.nvim_buf_add_highlight(w.buf, ns, hl, i - 1, 0, -1)
      end
    end
    local width = math.max(1, math.min(100, vim.o.columns - 4))
    local height = math.max(1, math.min(#lines, vim.o.lines - 4))
    vim.api.nvim_win_set_config(w.win, {
      relative = "editor",
      row = 1,
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = height,
    })
    pcall(vim.api.nvim_win_set_cursor, w.win, { math.min(3, #lines), 0 })
  else
    for i, w in ipairs(s.windows) do
      if owned(w) then
        local source = i == 1 and "head_contents" or "working_contents"
        set_lines(w.buf, diff[source](s.root, s.path) or {})
        vim.wo[w.win].winbar = (i == 1 and "HEAD · " or "disk · ") .. label:gsub("%%", "%%%%")
      end
    end
    hunk_position()
  end
end
local function prepare(entry, opts)
  local root = opts and opts.root or diff.git_root()
  if not root or not entry or not entry.rel_path then
    notify("No review target")
    return nil
  end
  local comparison, err = diff.review(root, entry.rel_path)
  if not comparison then
    notify(err)
    return nil
  end
  return root, comparison
end
local function new_session(root, path, comparison, o, mode)
  serial = serial + 1
  return {
    id = serial,
    root = root,
    path = path,
    fd = comparison,
    hunk = 1,
    origin = o,
    mode = mode,
    windows = {},
    buffers = {},
  }
end
--- Preview the first current hunk in a bounded unified float.
---@param entry TimelineEntry
---@param opts? {root: string}
---@return boolean
function M.preview(entry, opts)
  local root, comparison = prepare(entry, opts)
  if not root then
    return false
  end
  local o = session and session.origin or origin()
  M.close(false)
  session = new_session(root, entry.rel_path, comparison, o, "preview")
  local s = session
  local buf = scratch(s, "hunk", {})
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 1,
    col = 1,
    width = math.max(1, math.min(100, vim.o.columns - 4)),
    height = math.max(1, math.min(12, vim.o.lines - 4)),
    border = "rounded",
    style = "minimal",
  })
  vim.wo[win].wrap = true
  s.windows = { { win = win, buf = buf } }
  keys(buf, true)
  draw()
  return true
end
--- Open/reuse a separate native diff tab; never collapse the original layout.
---@param entry TimelineEntry
---@param opts? {root: string}
---@return boolean
function M.open(entry, opts)
  local root, comparison = prepare(entry, opts)
  if not root then
    return false
  end
  if
    session
    and session.mode == "full"
    and session.root == root
    and owned(session.windows[1])
    and owned(session.windows[2])
  then
    session.path = entry.rel_path
    session.fd = comparison
    session.hunk = 1
    vim.api.nvim_set_current_win(session.windows[2].win)
    draw()
    return true
  end
  local o = session and session.origin or origin()
  M.close(false)
  session = new_session(root, entry.rel_path, comparison, o, "full")
  local s = session
  vim.cmd("tabnew")
  s.tab = vim.api.nvim_get_current_tabpage()
  local old = scratch(s, "HEAD", diff.head_contents(root, s.path) or {})
  local new = scratch(s, "disk", diff.working_contents(root, s.path) or {})
  local left = vim.api.nvim_get_current_win()
  local empty = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(left, old)
  if
    vim.api.nvim_buf_is_valid(empty)
    and not vim.bo[empty].modified
    and #vim.fn.win_findbuf(empty) == 0
  then
    pcall(vim.api.nvim_buf_delete, empty, { force = false })
  end
  local right = vim.api.nvim_open_win(
    new,
    true,
    { split = config.options.diff_layout == "horizontal" and "below" or "right", win = left }
  )
  s.windows = { { win = left, buf = old }, { win = right, buf = new } }
  for _, w in ipairs(s.windows) do
    vim.api.nvim_win_call(w.win, function()
      vim.cmd("diffthis")
    end)
    keys(w.buf, false)
  end
  draw()
  return true
end
--- Navigate hunks with bounded indices.
---@param delta integer
---@return boolean
function M.navigate_hunk(delta)
  if not session or not session.fd then
    return false
  end
  local next_index = math.max(1, math.min(#session.fd.hunks, session.hunk + delta))
  if next_index == session.hunk then
    return false
  end
  session.hunk = next_index
  if session.mode == "preview" then
    draw()
  else
    hunk_position()
  end
  return true
end
--- Refresh safe changed paths and move deterministically, skipping binaries.
---@param delta integer
---@return boolean
function M.navigate_file(delta)
  if not session or session.mode ~= "full" then
    return false
  end
  local paths, err = diff.changed_files(session.root)
  if err then
    notify(err)
    return false
  end
  local index = delta > 0 and 0 or #paths + 1
  for i, path in ipairs(paths) do
    if path == session.path then
      index = i
      break
    end
  end
  for i = index + delta, delta > 0 and #paths or 1, delta > 0 and 1 or -1 do
    local comparison, message = diff.review(session.root, paths[i])
    if comparison then
      session.path = paths[i]
      session.fd = comparison
      session.hunk = 1
      draw()
      return true
    end
    notify(paths[i] .. ": " .. message)
  end
  notify("No more current changes")
  return false
end
--- Recompute the current comparison and retain/clamp the selected hunk.
---@return boolean
function M.refresh()
  if not session then
    return false
  end
  session.fd, session.error = diff.review(session.root, session.path)
  if session.error then
    notify(session.error)
  end
  draw()
  return session.fd ~= nil
end
---@return boolean
function M.is_open()
  return session ~= nil
end
vim.api.nvim_create_autocmd("WinClosed", {
  group = vim.api.nvim_create_augroup("AgentLensReviewCleanup", { clear = true }),
  callback = function()
    if guard or not session then
      return
    end
    local s = session
    vim.schedule(function()
      if session ~= s then
        return
      end
      cleanup_buffers(s)
      local any = false
      for _, w in ipairs(s.windows) do
        if owned(w) then
          any = true
        end
      end
      if not any then
        session = nil
        cleanup_buffers(s)
      end
    end)
  end,
})
return M
