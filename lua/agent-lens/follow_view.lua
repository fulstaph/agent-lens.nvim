--- Zed-style live navigation to the active agent location.
local config = require("agent-lens.config")
local status = require("agent-lens.status")
local motion = require("agent-lens.motion")

local M = {}
local uv = vim.uv
local namespace = vim.api.nvim_create_namespace("agent_lens_follow")
local caret_namespace = vim.api.nvim_create_namespace("agent_lens_caret")
local change_namespace = vim.api.nvim_create_namespace("agent_lens_draft_change")
local frozen = false
local guard = false
local current_win
local on_input
local opts = {}
local owned
local window_mode = "current"
local function owns_window()
  return owned
    and vim.api.nvim_win_is_valid(owned.win)
    and vim.api.nvim_win_get_buf(owned.win) == owned.buf
end
local function owned_bar()
  if owns_window() and (owned.bar == nil or vim.wo[owned.win].winbar == owned.bar) then
    owned.bar = status.statusline()
    vim.wo[owned.win].winbar = owned.bar
  end
end
local target
local mark
local warned_split = false
local preview

--- Run fn with input provenance suppressed. The previous state is restored even
--- if fn errors, and nested calls (synchronous reveal frames) keep the outer guard.
local function guarded(fn, ...)
  local previous = guard
  guard = true
  local ok, result = pcall(fn, ...)
  guard = previous
  if not ok then
    error(result, 0)
  end
  return result
end

local function clear_mark()
  if mark and vim.api.nvim_buf_is_valid(mark.buf) then
    vim.api.nvim_buf_clear_namespace(mark.buf, namespace, 0, -1)
    vim.api.nvim_buf_clear_namespace(mark.buf, caret_namespace, 0, -1)
  end
  mark = nil
end

local target_path = require("agent-lens.paths").resolve
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
      local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
      pcall(vim.api.nvim_win_set_buf, win, source)
      if owned and owned.win == win then
        owned.buf = source
      end
      view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(source))
      local text = vim.api.nvim_buf_get_lines(source, view.lnum - 1, view.lnum, false)[1] or ""
      view.col = math.min(view.col, math.max(0, #text - 1))
      pcall(vim.api.nvim_win_call, win, function()
        vim.fn.winrestview(view)
      end)
    end
  end
  pcall(vim.api.nvim_buf_delete, previous.buf, { force = true })
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

local function create_preview(root, event)
  -- Seed from bounded disk contents, keeping unsaved source buffers independent.
  local baseline = preview_baseline(root, event.path)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "agent-lens://draft/" .. event.path)
  vim.b[buf].agent_lens_preview = true
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = vim.filetype.match({ filename = root .. "/" .. event.path }) or ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, baseline)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  return { buf = buf, root = root, path = event.path, call_id = event.toolCallId }
end

local function is_editor_window(win, target_buf)
  if not win or not motion.plain_window(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local draft = vim.b[buf].agent_lens_preview == true
  if
    not draft
    and (vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf):match("^agent%-lens://"))
  then
    return false
  end
  if vim.wo[win].winfixbuf and buf ~= target_buf then
    return false
  end
  return buf == target_buf or not vim.bo[buf].modified
end

local function create_window(buf)
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    split = window_mode == "split" and opts.split and opts.split.position or "right",
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
  if window_mode == "split" then
    owned = { win = win, buf = buf, tab = vim.api.nvim_get_current_tabpage() }
    local width = opts.split and opts.split.width or 0
    if type(width) ~= "number" or width < 0 or width % 1 ~= 0 then
      width = 0
    end
    local available = vim.o.columns
    width = width == 0 and math.floor(available / 2) or width
    pcall(vim.api.nvim_win_set_width, win, math.max(1, math.min(width, available - 2)))
    owned_bar()
  end
  return win
end

local function select_window(buf)
  if window_mode == "split" then
    if owned then
      if not owns_window() then
        owned = nil
        on_input("agent split closed or reused", false)
        return nil
      end
      if owned.tab ~= vim.api.nvim_get_current_tabpage() then
        return nil
      end
      if is_editor_window(owned.win, buf) then
        return owned.win
      end
      on_input("agent split protected", false)
      return nil
    end
    return create_window(buf)
  end
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
local phase_labels = { progress = " · drafting", start = " · applying" }
local function label_for(current)
  local agent = current.agent or config.options.agent_name
  return "  AGENT · " .. agent .. (phase_labels[current.phase] or "")
end

local function render()
  if frozen or not target or not target.path then
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
  current_win = win
  local ok = vim.api.nvim_win_get_buf(win) == buf or pcall(vim.api.nvim_win_set_buf, win, buf)
  if not ok then
    win = create_window(buf)
    if not win then
      return false
    end
  end

  if owned and owned.win == win then
    owned.buf = buf
    owned_bar()
  end
  local requested_line = drafting and preview.line or target.line
  local line = math.max(1, math.min(requested_line or 1, vim.api.nvim_buf_line_count(buf)))
  local placed = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, line - 1, 0, {
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
  mark = { buf = buf }
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

--- Configure input provenance and view lifecycle.
---@param options table
---@param callback fun(reason: string, insert: boolean)
function M.setup(options, callback)
  M.clear()
  opts = options
  window_mode = opts.window or "current"
  on_input = callback
  local ns = vim.api.nvim_create_namespace("agent_lens_input")
  vim.on_key(function(key, typed)
    if guard or not current_win or vim.api.nvim_get_current_win() ~= current_win then
      return
    end
    if typed == "" then
      return
    end
    local editing = key:match("^[iIaAoORcsCS]$") ~= nil
    if frozen and not editing then
      return
    end
    if key ~= "" and (opts.auto_pause ~= false or editing) then
      on_input("navigation", editing)
    end
  end, ns)
  local group = vim.api.nvim_create_augroup("AgentLensFollowInput", { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function()
      if guard or vim.api.nvim_get_current_win() ~= current_win then
        return
      end
      on_input("editing", true)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "TabLeave", "CmdlineEnter" }, {
    group = group,
    callback = function(ev)
      if
        not guard
        and not frozen
        and current_win
        and vim.api.nvim_get_current_win() == current_win
      then
        if ev.event == "CmdlineEnter" or window_mode == "current" then
          on_input(ev.event == "CmdlineEnter" and "command line" or "left followed window", false)
        elseif ev.event == "TabLeave" then
          M.freeze()
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      if
        not guard
        and window_mode == "split"
        and owned
        and owned.tab == vim.api.nvim_get_current_tabpage()
      then
        on_input("returned", false)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      if not guard and owned and tonumber(ev.match) == owned.win then
        owned = nil
        current_win = nil
        on_input("agent split closed", false)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function()
      if
        not guard
        and owned
        and vim.api.nvim_win_is_valid(owned.win)
        and vim.api.nvim_win_get_buf(owned.win) ~= owned.buf
      then
        owned = nil
        current_win = nil
        on_input("agent split reused", false)
      end
    end,
  })
  vim.api.nvim_create_autocmd(
    "User",
    { group = group, pattern = "AgentLensStatusChanged", callback = owned_bar }
  )
end
local function render_next(next_target, event)
  frozen = false
  target = vim.deepcopy(next_target)
  if
    preview
    and (
      preview.root ~= target.root
      or preview.path ~= target.path
      or preview.call_id ~= target.call_id
    )
  then
    clear_preview()
  end
  if target.phase == "success" then
    if preview and motion.is_revealing(preview.buf) then
      preview.settled = true
    else
      clear_preview()
    end
  elseif event and (not preview or preview.sequence ~= event.sequence) then
    if not preview or not vim.api.nvim_buf_is_valid(preview.buf) then
      preview = create_preview(target.root, event)
    end
    preview.sequence = event.sequence
    local buf = preview.buf
    motion.reveal(buf, event.lines, event.line, function(row, col, done)
      if frozen or not preview or preview.buf ~= buf then
        return
      end
      preview.line = row
      preview.column = col
      vim.api.nvim_buf_clear_namespace(buf, change_namespace, 0, -1)
      vim.api.nvim_buf_set_extmark(buf, change_namespace, row - 1, 0, {
        line_hl_group = config.options.highlights.added,
        priority = 150,
      })
      guarded(function()
        if done and preview.settled then
          target.line = row
          clear_preview()
        end
        render()
      end)
    end)
  end
  return render()
end

--- Render one latest validated target and optional bounded snapshot.
---@param next_target FollowTarget
---@param event? table
---@return boolean
function M.render(next_target, event)
  if window_mode == "split" and owned and owned.tab ~= vim.api.nvim_get_current_tabpage() then
    return false
  end
  local mode = vim.fn.mode(1)
  local unrelated_insert = window_mode == "split"
    and owned
    and owned.win ~= vim.api.nvim_get_current_win()
    and mode:match("^[iR]")
  if vim.fn.getcmdwintype() ~= "" or (mode:match("^[icRr]") and not unrelated_insert) then
    on_input("unsafe editor mode", false)
    return false
  end
  return guarded(render_next, next_target, event)
end
--- Freeze pixels and cancel all pending animation.
function M.freeze()
  frozen = true
  motion.stop()
  if preview then
    preview.sequence = nil
  end
end
--- Hand the current draft back to its real source, preserving unsaved text.
---@return boolean
function M.handoff()
  if not preview then
    return true
  end
  if not target_buffer(preview.root, preview.path, true) then
    return false
  end
  guarded(clear_preview)
  return true
end
--- Return the followed window and draft ownership facts.
---@return {win?: integer, buf?: integer, draft: boolean}
function M.current()
  return {
    win = current_win,
    buf = current_win and vim.api.nvim_win_is_valid(current_win) and vim.api.nvim_win_get_buf(
      current_win
    ) or nil,
    draft = preview ~= nil,
  }
end
local function release_owned()
  if owns_window() then
    if not vim.bo[owned.buf].modified and #vim.api.nvim_tabpage_list_wins(owned.tab) > 1 then
      pcall(vim.api.nvim_win_close, owned.win, true)
    elseif owned.bar and vim.wo[owned.win].winbar == owned.bar then
      vim.wo[owned.win].winbar = ""
    end
  end
  owned = nil
end
--- Release drafts and marks, leaving real source text intact.
function M.clear()
  guarded(function()
    motion.stop()
    clear_preview()
    clear_mark()
    release_owned()
  end)
  target = nil
  current_win = nil
  frozen = false
end
---@return 'current'|'split'
function M.window()
  return window_mode
end
--- Select a window mode, releasing only an unused owned split.
---@param mode string
---@return boolean
function M.set_window(mode)
  if mode ~= "current" and mode ~= "split" then
    return false
  end
  guarded(release_owned)
  current_win = nil
  window_mode = mode
  return true
end
return M
