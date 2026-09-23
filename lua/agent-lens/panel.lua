--- Timeline panel UI.
--- Floating or split panel showing the chronological feed of file edits.

local config = require("agent-lens.config")
local timeline = require("agent-lens.timeline")

local M = {}

---@type integer|nil Buffer number for the timeline panel
M._buf = nil

---@type integer|nil Window number for the timeline panel
M._win = nil

---@type integer Currently selected entry index (1-based into displayed list)
M._cursor = 1

--- Format a timestamp as a relative time string.
---@param ts integer Unix timestamp
---@return string
local function relative_time(ts)
  local diff = os.time() - ts
  if diff < 5 then
    return "just now"
  elseif diff < 60 then
    return diff .. "s ago"
  elseif diff < 3600 then
    return math.floor(diff / 60) .. "m ago"
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. "h ago"
  else
    return math.floor(diff / 86400) .. "d ago"
  end
end

--- Render a timeline entry as display lines.
---@param entry table TimelineEntry
---@return string[] lines
---@return table[] highlights {line, col_start, col_end, group}
local function render_entry(entry)
  local icon = entry.kind == "read" and "R " or "  "

  local stats = ""
  if entry.stats.added > 0 then
    stats = stats .. "+" .. entry.stats.added
  end
  if entry.stats.removed > 0 then
    if #stats > 0 then
      stats = stats .. " "
    end
    stats = stats .. "-" .. entry.stats.removed
  end

  if entry.kind == "read" then
    stats = "READ · " .. entry.agent
  end
  local time_str = relative_time(entry.timestamp)

  -- Shorten the path if too long
  local max_path = config.options.timeline_width - 6
  local short_path = entry.rel_path
  if #short_path > max_path then
    short_path = "…" .. short_path:sub(-max_path + 1)
  end

  local line1 = icon .. short_path
  local line2 = "  " .. time_str .. "  " .. stats

  local hls = {
    {
      line = 0,
      col_start = #icon,
      col_end = #line1,
      group = config.options.highlights.timeline_file,
    },
    {
      line = 1,
      col_start = 2,
      col_end = 2 + #time_str,
      group = config.options.highlights.timeline_time,
    },
  }

  if entry.stats.added > 0 then
    local add_str = "+" .. entry.stats.added
    local add_start = line2:find(add_str, 1, true)
    if add_start then
      hls[#hls + 1] = {
        line = 1,
        col_start = add_start - 1,
        col_end = add_start - 1 + #add_str,
        group = config.options.highlights.added,
      }
    end
  end

  if entry.stats.removed > 0 then
    local rm_str = "-" .. entry.stats.removed
    local rm_start = line2:find(rm_str, 1, true)
    if rm_start then
      hls[#hls + 1] = {
        line = 1,
        col_start = rm_start - 1,
        col_end = rm_start - 1 + #rm_str,
        group = config.options.highlights.removed,
      }
    end
  end

  return { line1, line2 }, hls
end

--- Create the timeline buffer (unlisted, scratch).
---@return integer buf
local function create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "agent-lens-timeline"
  vim.api.nvim_buf_set_name(buf, "agent-lens://timeline")
  return buf
end

--- Refresh the timeline buffer contents.
function M.render()
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then
    return
  end

  local entries = timeline.list()
  local lines = {}
  local all_hls = {}

  -- Header
  local summary = timeline.summary()
  local header = string.format("  Agent Lens  %d events · %d files", summary.total, summary.files)
  lines[#lines + 1] = header
  lines[#lines + 1] = string.rep("─", config.options.timeline_width)

  if #entries == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Watching for file edits…"
    lines[#lines + 1] = ""
    lines[#lines + 1] = config.options.reads.enabled and "  Waiting for Pi/OMP read events."
      or "  No edits detected yet."
  else
    for i, entry in ipairs(entries) do
      local entry_lines, entry_hls = render_entry(entry)
      local base_line = #lines

      for _, el in ipairs(entry_lines) do
        lines[#lines + 1] = el
      end
      lines[#lines + 1] = "" -- separator

      for _, hl in ipairs(entry_hls) do
        all_hls[#all_hls + 1] = {
          line = base_line + hl.line,
          col_start = hl.col_start,
          col_end = hl.col_end,
          group = hl.group,
          entry_idx = i,
        }
      end
    end
  end

  vim.bo[M._buf].modifiable = true
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, lines)
  vim.bo[M._buf].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("agent_lens_timeline")
  vim.api.nvim_buf_clear_namespace(M._buf, ns, 0, -1)

  -- Header highlight
  vim.api.nvim_buf_add_highlight(M._buf, ns, config.options.highlights.header, 0, 0, -1)

  for _, hl in ipairs(all_hls) do
    vim.api.nvim_buf_add_highlight(M._buf, ns, hl.group, hl.line, hl.col_start, hl.col_end)
  end

  -- Highlight selected entry
  if M._cursor and #entries > 0 then
    local sel_line = 2 + (M._cursor - 1) * 3 -- header(2) + 3 lines per entry
    if sel_line < #lines then
      vim.api.nvim_buf_add_highlight(
        M._buf,
        ns,
        config.options.highlights.timeline_selected,
        sel_line,
        0,
        -1
      )
      vim.api.nvim_buf_add_highlight(
        M._buf,
        ns,
        config.options.highlights.timeline_selected,
        sel_line + 1,
        0,
        -1
      )
    end
  end
end

--- Open the timeline panel.
function M.open()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    M.render()
    return
  end

  M._buf = create_buf()
  M._cursor = 1

  local pos = config.options.timeline_position
  if pos == "right" then
    vim.cmd("botright vsplit")
    M._win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M._win, M._buf)
    vim.api.nvim_win_set_width(M._win, config.options.timeline_width)
  elseif pos == "left" then
    vim.cmd("topleft vsplit")
    M._win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M._win, M._buf)
    vim.api.nvim_win_set_width(M._win, config.options.timeline_width)
  else -- bottom
    vim.cmd("botright split")
    M._win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M._win, M._buf)
    vim.api.nvim_win_set_height(M._win, config.options.timeline_height)
  end

  -- Window options
  vim.wo[M._win].number = false
  vim.wo[M._win].relativenumber = false
  vim.wo[M._win].signcolumn = "no"
  vim.wo[M._win].foldcolumn = "0"
  vim.wo[M._win].wrap = false
  vim.wo[M._win].spell = false
  vim.wo[M._win].cursorline = false
  vim.wo[M._win].winfixwidth = true

  M._setup_keymaps()
  M.render()
end

--- Close the timeline panel.
function M.close()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    vim.api.nvim_win_close(M._win, true)
  end
  M._win = nil
  M._buf = nil
end

--- Toggle the timeline panel.
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Check if the timeline panel is open.
---@return boolean
function M.is_open()
  return M._win ~= nil and vim.api.nvim_win_is_valid(M._win)
end

--- Move selection in the timeline.
---@param delta integer +1 for next, -1 for prev
function M.move(delta)
  local entries = timeline.list()
  if #entries == 0 then
    return
  end
  M._cursor = math.max(1, math.min(#entries, M._cursor + delta))
  M.render()

  -- Move cursor in the window to the selected entry
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    local target_line = 2 + (M._cursor - 1) * 3 + 1 -- 1-based
    pcall(vim.api.nvim_win_set_cursor, M._win, { target_line, 0 })
  end
end

--- Get the currently selected entry.
---@return table|nil TimelineEntry
function M.selected()
  local entries = timeline.list()
  if #entries == 0 or M._cursor > #entries then
    return nil
  end
  return entries[M._cursor]
end

--- Setup buffer-local keymaps for the timeline.
function M._setup_keymaps()
  if not M._buf then
    return
  end

  local opts = { buffer = M._buf, nowait = true, silent = true }

  vim.keymap.set("n", config.options.keymaps.close, function()
    M.close()
  end, vim.tbl_extend("force", opts, { desc = "Close agent-lens" }))

  vim.keymap.set("n", "j", function()
    M.move(1)
  end, vim.tbl_extend("force", opts, { desc = "Next edit" }))

  vim.keymap.set("n", "k", function()
    M.move(-1)
  end, vim.tbl_extend("force", opts, { desc = "Previous edit" }))

  vim.keymap.set("n", config.options.keymaps.next_edit, function()
    M.move(1)
  end, vim.tbl_extend("force", opts, { desc = "Next edit" }))

  vim.keymap.set("n", config.options.keymaps.prev_edit, function()
    M.move(-1)
  end, vim.tbl_extend("force", opts, { desc = "Previous edit" }))

  vim.keymap.set("n", config.options.keymaps.open_diff, function()
    require("agent-lens").show_diff()
  end, vim.tbl_extend("force", opts, { desc = "Open edit diff or read file" }))

  vim.keymap.set("n", config.options.keymaps.refresh, function()
    M.render()
  end, vim.tbl_extend("force", opts, { desc = "Refresh timeline" }))
end

return M
