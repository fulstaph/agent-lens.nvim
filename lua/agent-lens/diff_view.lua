--- Diff viewer.
--- Opens a side-by-side or inline diff for a timeline entry.

local config = require("agent-lens.config")
local diff_engine = require("agent-lens.diff")

local M = {}

---@type integer|nil Window for old content
M._win_old = nil
---@type integer|nil Window for new content
M._win_new = nil
---@type integer|nil Buffer for old content
M._buf_old = nil
---@type integer|nil Buffer for new content
M._buf_new = nil

--- Open a diff view for a timeline entry.
---@param entry table TimelineEntry
function M.open(entry)
  M.close()

  local root = diff_engine.git_root()
  if not root then
    vim.notify("[agent-lens] Not in a git repository", vim.log.levels.WARN)
    return
  end

  local old_lines = diff_engine.head_contents(root, entry.rel_path)
  local new_lines = diff_engine.working_contents(root, entry.rel_path)

  if not old_lines and not new_lines then
    vim.notify("[agent-lens] Cannot read file: " .. entry.rel_path, vim.log.levels.WARN)
    return
  end

  -- Defaults for new / deleted files
  old_lines = old_lines or {}
  new_lines = new_lines or {}

  -- Detect filetype from extension
  local ft = vim.filetype.match({ filename = entry.rel_path }) or ""

  -- Create old buffer
  M._buf_old = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(M._buf_old, 0, -1, false, old_lines)
  vim.bo[M._buf_old].buftype = "nofile"
  vim.bo[M._buf_old].bufhidden = "wipe"
  vim.bo[M._buf_old].swapfile = false
  vim.bo[M._buf_old].modifiable = false
  vim.bo[M._buf_old].filetype = ft
  vim.api.nvim_buf_set_name(M._buf_old, "agent-lens://old/" .. entry.rel_path)

  -- Create new buffer
  M._buf_new = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(M._buf_new, 0, -1, false, new_lines)
  vim.bo[M._buf_new].buftype = "nofile"
  vim.bo[M._buf_new].bufhidden = "wipe"
  vim.bo[M._buf_new].swapfile = false
  vim.bo[M._buf_new].modifiable = false
  vim.bo[M._buf_new].filetype = ft
  vim.api.nvim_buf_set_name(M._buf_new, "agent-lens://new/" .. entry.rel_path)

  -- Open in split
  -- First, go to a normal window (not the timeline panel)
  local panel = require("agent-lens.panel")
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    if win ~= panel._win and not name:match("^agent%-lens://") then
      vim.api.nvim_set_current_win(win)
      break
    end
  end

  if config.options.diff_layout == "vertical" then
    -- Open old on the left
    vim.cmd("edit agent-lens://placeholder | only")
    -- Actually set the buffer
    vim.api.nvim_set_current_buf(M._buf_old)
    M._win_old = vim.api.nvim_get_current_win()

    vim.cmd("rightbelow vsplit")
    vim.api.nvim_set_current_buf(M._buf_new)
    M._win_new = vim.api.nvim_get_current_win()
  else
    vim.api.nvim_set_current_buf(M._buf_old)
    M._win_old = vim.api.nvim_get_current_win()

    vim.cmd("rightbelow split")
    vim.api.nvim_set_current_buf(M._buf_new)
    M._win_new = vim.api.nvim_get_current_win()
  end

  -- Enable Neovim's built-in diff mode on both windows
  vim.api.nvim_set_current_win(M._win_old)
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(M._win_new)
  vim.cmd("diffthis")

  -- Window titles via winbar
  vim.wo[M._win_old].winbar = " HEAD: " .. entry.rel_path
  vim.wo[M._win_new].winbar = " Working: " .. entry.rel_path

  -- Buffer-local keymap to close
  for _, buf in ipairs({ M._buf_old, M._buf_new }) do
    vim.keymap.set("n", config.options.keymaps.close, function()
      M.close()
    end, { buffer = buf, nowait = true, silent = true, desc = "Close diff" })
  end

  -- Re-open the timeline panel if it was open
  if panel.is_open() then
    -- The panel was likely closed by :only — reopen it
    panel.open()
  end

  -- Focus the new content window
  if M._win_new and vim.api.nvim_win_is_valid(M._win_new) then
    vim.api.nvim_set_current_win(M._win_new)
  end
end

--- Close the diff viewer.
function M.close()
  for _, win in ipairs({ M._win_old, M._win_new }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.cmd("diffoff")
      vim.api.nvim_win_close(win, true)
    end
  end
  M._win_old = nil
  M._win_new = nil
  M._buf_old = nil
  M._buf_new = nil
end

--- Check if the diff view is open.
---@return boolean
function M.is_open()
  return M._win_new ~= nil and vim.api.nvim_win_is_valid(M._win_new)
end

return M
