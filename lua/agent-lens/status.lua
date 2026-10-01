--- Observable metadata only; never draft contents or inferred host liveness.
local M = {}
---@class FollowState
---@field control 'off'|'following'|'paused'
---@field window 'current'|'split'
---@field reason? string
---@class ActivityState
---@field phase 'idle'|'reading'|'drafting'|'applying'|'settled'|'failed'
---@field tool? string
---@field path? string
---@field line? integer
---@field call_id? string
---@class ChannelState
---@field state string
---@field peers? integer
---@field last_valid_at? integer
---@field error? string
---@class StatusSnapshot
---@field watcher {state: string, root?: string}
---@field follow FollowState
---@field activity ActivityState
---@field metadata ChannelState
---@field preview ChannelState
local fields = {
  watcher = { "state", "root" },
  follow = { "control", "window", "reason" },
  activity = { "phase", "tool", "path", "line", "call_id" },
  metadata = { "state", "last_valid_at", "error" },
  preview = { "state", "peers", "last_valid_at", "error" },
}
local snapshot
local scheduled = false
local details
local function changed()
  if scheduled then
    return
  end
  scheduled = true
  vim.schedule(function()
    scheduled = false
    vim.api.nvim_exec_autocmds("User", { pattern = "AgentLensStatusChanged", modeline = false })
  end)
end
--- Reset all observable facts.
function M.reset()
  snapshot = {
    watcher = { state = "stopped" },
    follow = { control = "off", window = "current" },
    activity = { phase = "idle" },
    metadata = { state = "disabled" },
    preview = { state = "disabled" },
  }
  changed()
end
--- Replace a section using copied, declared scalar fields.
---@param section string
---@param value table
function M.set(section, value)
  if not fields[section] or type(value) ~= "table" then
    return
  end
  local next_value = {}
  for _, k in ipairs(fields[section]) do
    if type(value[k]) == "string" or type(value[k]) == "number" then
      next_value[k] = value[k]
    end
  end
  if vim.deep_equal(snapshot[section], next_value) then
    return
  end
  snapshot[section] = next_value
  changed()
end
--- Get a copy that consumers can safely modify.
---@return StatusSnapshot
function M.get()
  return vim.deepcopy(snapshot)
end
--- Format compact human-readable control/activity.
---@param value? StatusSnapshot
---@return string
function M.compact(value)
  value = value or snapshot
  local labels = {
    idle = "Waiting",
    reading = "Reading",
    drafting = "Drafting",
    applying = "Applying",
    settled = "Settled",
    failed = "Failed",
  }
  local text = value.follow.control == "paused" and "Paused"
    or value.follow.control == "off" and "Follow off"
    or labels[value.activity.phase]
    or "Waiting"
  if value.activity.path then
    text = text
      .. " · "
      .. value.activity.path
      .. (value.activity.line and ":" .. value.activity.line or "")
  end
  return text
end
--- Optional statusline expression; escape Neovim format directives.
---@return string
function M.statusline()
  return M.compact():gsub("%%", "%%%%")
end
--- Close only the owned details float.
function M.close()
  if
    details
    and vim.api.nvim_win_is_valid(details.win)
    and vim.api.nvim_win_get_buf(details.win) == details.buf
  then
    pcall(vim.api.nvim_win_close, details.win, true)
  end
  if details and vim.api.nvim_buf_is_valid(details.buf) and not vim.bo[details.buf].modified then
    pcall(vim.api.nvim_buf_delete, details.buf, { force = true })
  end
  details = nil
end
--- Show the current observable facts without changing user statuslines.
function M.open()
  M.close()
  local s = M.get()
  local lines = {
    "Agent Lens",
    M.compact(s),
    "Root: " .. (s.watcher.root or "none"),
    "Watcher: " .. s.watcher.state,
    "Follow: " .. s.follow.control .. " / " .. s.follow.window,
  }
  if s.follow.reason then
    lines[#lines + 1] = "Reason: " .. s.follow.reason
  end
  lines[#lines + 1] = "Activity: " .. s.activity.phase
  for _, section in ipairs({ "metadata", "preview" }) do
    local c = s[section]
    lines[#lines + 1] = section .. ": " .. c.state
    if c.last_valid_at then
      lines[#lines + 1] = "Last valid receipt: " .. os.date("%H:%M:%S", c.last_valid_at)
    end
    if c.error then
      lines[#lines + 1] = "Error: " .. c.error
    end
  end
  lines[#lines + 1] = "Resume: :AgentLensResume  Restart: :AgentLensStart"
  lines[#lines + 1] = "q / Esc close"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.max(1, math.min(68, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 1,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
  })
  vim.wo[win].wrap = true
  details = { win = win, buf = buf }
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, M.close, { buffer = buf, nowait = true })
  end
end
M.reset()
return M
