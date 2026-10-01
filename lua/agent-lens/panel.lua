--- Stable timeline sidebar; projections and action dispatch remain separate.
local config = require("agent-lens.config")
local timeline = require("agent-lens.timeline")
local model = require("agent-lens.panel_model")
local status = require("agent-lens.status")
local M = { _buf = nil, _win = nil, _cursor = 1 }
local options = { view = "files", filter = "all", unread_only = false, expanded = {} }
local rows = {}
local key
local actions = {}
local ns = vim.api.nvim_create_namespace("agent_lens_timeline")
local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width < 2 then
    return vim.fn.strcharpart(text, 0, math.max(0, width))
  end
  local out = ""
  for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if vim.fn.strdisplaywidth(out .. c .. "…") > width then
      break
    end
    out = out .. c
  end
  return out .. "…"
end
local function row_line(i)
  return 5 + (i - 1) * 2
end
local function selected_row()
  for _, r in ipairs(rows) do
    if r.key == key then
      return r
    end
  end
end
--- Initialize the runtime projection.
---@param opts table
function M.setup(opts)
  options = {
    view = opts.view == "events" and "events" or "files",
    filter = opts.filter or "all",
    unread_only = false,
    expanded = {},
  }
  rows = {}
  key = nil
  M._cursor = 1
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("AgentLensPanelStatus", { clear = true }),
    pattern = "AgentLensStatusChanged",
    callback = function()
      if M.is_open() then
        M.render()
      end
    end,
  })
end
--- Set orchestration callbacks without coupling the model to editor APIs.
---@param value {open: fun(entry: TimelineEntry): boolean, preview?: fun(entry: TimelineEntry): boolean, browse: fun()}
function M.set_actions(value)
  actions = value
  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    M._setup_keymaps()
  end
end
--- Select or cycle the in-session filter.
---@param filter? string
function M.set_filter(filter)
  local order = { all = "reads", reads = "edits", edits = "all" }
  filter = filter or order[options.filter]
  if not order[filter] then
    return
  end
  options.filter = filter
  M.render()
end
--- Refresh visible rows while preserving selection and screen offset.
---@param preserve_anchor? boolean
function M.render(preserve_anchor)
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then
    return
  end
  local before = M.is_open() and vim.api.nvim_win_call(M._win, vim.fn.winsaveview)
  local next_rows = model.project(timeline.list(), options, timeline.unread_ids())
  key = model.select(next_rows, rows, key)
  rows = next_rows
  local s = timeline.summary()
  local width = M.is_open() and vim.api.nvim_win_get_width(M._win) or config.options.timeline_width
  local lines = {
    "Agent Lens · " .. s.unread .. " new",
    status.compact(),
    "Latest retained + " .. s.added .. " / - " .. s.removed,
    options.view .. " · " .. options.filter .. (options.unread_only and " · new only" or ""),
  }
  for i, r in ipairs(rows) do
    local marker = r.kind == "file" and (options.expanded[r.path] and "v " or "> ")
      or (r.entry.kind == "read" and "R " or "E ")
    lines[#lines + 1] = string.rep(" ", r.depth * 2) .. marker .. r.path
    local stats = r.stats and (" +" .. r.stats.added .. "/-" .. r.stats.removed) or ""
    lines[#lines + 1] = string.rep(" ", r.depth * 2)
      .. (r.kind == "file" and (r.reads .. " reads · " .. r.edits .. " edits") or (os.date(
        "%H:%M:%S",
        r.entry.timestamp
      ) .. " · " .. (r.entry.kind == "read" and "read" or r.entry.status)))
      .. stats
      .. (r.unread > 0 and (" · " .. r.unread .. " new") or "")
    if r.key == key then
      M._cursor = i
    end
  end
  if #rows == 0 then
    lines[#lines + 1] = s.total == 0 and "No activity yet."
      or "No matching activity. f: filter / u: new"
    lines[#lines + 1] = "Metadata: " .. status.get().metadata.state
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "CR open · p preview · Tab expand"
  lines[#lines + 1] = "f filter · u new · m seen · g view"
  lines[#lines + 1] = "j/k move · R refresh · q close"
  for i, line in ipairs(lines) do
    lines[i] = truncate(line, width)
  end
  vim.bo[M._buf].modifiable = true
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, lines)
  vim.bo[M._buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M._buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(M._buf, ns, config.options.highlights.header, 0, 0, -1)
  for i, r in ipairs(rows) do
    vim.api.nvim_buf_add_highlight(
      M._buf,
      ns,
      config.options.highlights.timeline_file,
      row_line(i) - 1,
      0,
      -1
    )
    vim.api.nvim_buf_add_highlight(
      M._buf,
      ns,
      config.options.highlights.timeline_time,
      row_line(i),
      0,
      -1
    )
    if r.key == key then
      vim.api.nvim_buf_add_highlight(
        M._buf,
        ns,
        config.options.highlights.timeline_selected,
        row_line(i) - 1,
        0,
        -1
      )
      if M.is_open() then
        local line = row_line(i)
        pcall(vim.api.nvim_win_set_cursor, M._win, { line, 0 })
        if before and preserve_anchor ~= false then
          local top = math.max(1, line - (before.lnum - before.topline))
          vim.api.nvim_win_call(M._win, function()
            vim.fn.winrestview({ lnum = line, col = 0, topline = top })
          end)
        end
      end
    end
  end
end
--- Open and focus the timeline.
function M.open()
  if M.is_open() then
    M.render()
    return
  end
  if actions.browse then
    actions.browse()
  end
  local buf = vim.api.nvim_create_buf(false, true)
  M._buf = buf
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "agent-lens-timeline"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, "agent-lens://timeline")
  local pos = config.options.timeline_position
  M._win = vim.api.nvim_open_win(
    buf,
    true,
    { split = pos == "bottom" and "below" or pos, win = vim.api.nvim_get_current_win() }
  )
  if pos == "bottom" then
    pcall(vim.api.nvim_win_set_height, M._win, config.options.timeline_height)
  else
    pcall(
      vim.api.nvim_win_set_width,
      M._win,
      math.min(config.options.timeline_width, math.max(1, vim.o.columns - 2))
    )
  end
  for k, v in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    wrap = false,
    spell = false,
    cursorline = false,
    winfixwidth = true,
  }) do
    vim.wo[M._win][k] = v
  end
  M._setup_keymaps()
  M.render(false)
end
--- Close only the owned panel window.
function M.close()
  if M.is_open() and #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(M._win)) > 1 then
    pcall(vim.api.nvim_win_close, M._win, true)
  end
  M._win = nil
  M._buf = nil
end
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end
---@return boolean
function M.is_open()
  return M._win ~= nil
    and vim.api.nvim_win_is_valid(M._win)
    and vim.api.nvim_win_get_buf(M._win) == M._buf
end
---@param delta integer
function M.move(delta)
  if #rows == 0 then
    return
  end
  M._cursor = math.max(1, math.min(#rows, M._cursor + delta))
  key = rows[M._cursor].key
  M.render(false)
end
---@return TimelineEntry|nil
function M.selected()
  local r = selected_row()
  return r and r.entry
end
---@return integer[]
function M.selected_ids()
  local r = selected_row()
  return r and vim.deepcopy(r.event_ids) or {}
end
local function act(callback)
  local entry = M.selected()
  local ids = M.selected_ids()
  if entry and callback and callback(entry) then
    timeline.acknowledge(ids)
    M.render()
  end
end
--- Register actions for owned timeline buffers.
function M._setup_keymaps()
  local function map(k, fn)
    if k and k ~= "" then
      vim.keymap.set("n", k, fn, { buffer = M._buf, nowait = true, silent = true })
    end
  end
  map(config.options.keymaps.close, M.close)
  map("<Esc>", M.close)
  map("j", function()
    M.move(1)
  end)
  map("k", function()
    M.move(-1)
  end)
  map(config.options.keymaps.next_edit, function()
    M.move(1)
  end)
  map(config.options.keymaps.prev_edit, function()
    M.move(-1)
  end)
  map(config.options.keymaps.open_diff, function()
    act(actions.open)
  end)
  if actions.preview then
    map("p", function()
      act(actions.preview)
    end)
  end
  map(config.options.keymaps.refresh, M.render)
  map("<Tab>", function()
    local r = selected_row()
    if r then
      options.expanded[r.path] = not options.expanded[r.path]
      M.render()
    end
  end)
  map("f", function()
    M.set_filter()
  end)
  map("u", function()
    options.unread_only = not options.unread_only
    M.render()
  end)
  map("m", function()
    timeline.mark_all_seen()
    M.render()
  end)
  map("g", function()
    options.view = options.view == "files" and "events" or "files"
    M.render()
  end)
end
return M
