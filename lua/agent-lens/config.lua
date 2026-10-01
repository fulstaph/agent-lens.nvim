---@class AgentLensHighlights
---@field added? string Highlight group for added lines
---@field removed? string Highlight group for removed lines
---@field header? string Highlight group for diff headers
---@field timeline_file? string Highlight group for filenames in timeline
---@field timeline_time? string Highlight group for timestamps in timeline
---@field timeline_selected? string Highlight group for selected timeline entry
---@field follow? string Highlight group for the active agent line
---@field follow_label? string Highlight group for the active agent label
---@field follow_cursor? string Highlight group for the live drafting caret

---@class AgentLensKeymaps
---@field toggle? string|false Toggle the timeline panel
---@field follow? string|false Toggle Follow Agent
---@field resume? string|false Resume Follow Agent
---@field next_edit? string|false Jump to next edit in timeline
---@field prev_edit? string|false Jump to previous edit in timeline
---@field open_diff? string|false Open diff for selected edit
---@field close? string|false Close the timeline panel
---@field refresh? string|false Refresh the timeline panel

---@class AgentLensFilter
---@field ignore_patterns? string[] Glob patterns to ignore, in addition to Git ignore rules

---@class AgentLensOpts
---@field enabled? boolean Auto-start watching on setup
---@field watch_dir? string Directory to watch (default: cwd / git root)
---@field debounce_ms? integer Debounce file change events
---@field max_timeline_entries? integer Max entries to keep in timeline
---@field timeline_position? "right" | "left" | "bottom" Panel position
---@field timeline_width? integer Width of timeline panel (for left/right)
---@field timeline? {view?: "files"|"events", filter?: "all"|"reads"|"edits"}
---@field timeline_height? integer Height of timeline panel (for bottom)
---@field diff_layout? "vertical" | "horizontal" Diff split direction
---@field auto_open_diff? boolean Auto-open diff on new edit
---@field highlights? AgentLensHighlights
---@field keymaps? AgentLensKeymaps
---@field filter? AgentLensFilter
---@field agent_name? string Display name for the agent
---@field reads? { enabled?: boolean, interval_ms?: integer } Opt-in Pi/OMP read feed
---@field inline? { enabled?: boolean } Show recent activity in file buffers
---@field follow? { enabled?: boolean, preview?: boolean, animation?: boolean, animation_ms?: integer, auto_pause?: boolean, window?: "current"|"split", split?: {position?: "left"|"right", width?: integer} } Follow locations and animate transient live drafts

local M = {}

---@type AgentLensOpts
M.defaults = {
  enabled = true,
  watch_dir = nil, -- auto-detect git root or cwd
  debounce_ms = 150,
  max_timeline_entries = 200,
  timeline_position = "right",
  timeline_width = 42,
  timeline_height = 15,
  timeline = { view = "files", filter = "all" },
  diff_layout = "vertical",
  auto_open_diff = false,
  reads = { enabled = false, interval_ms = 100 },
  inline = { enabled = true },
  follow = {
    enabled = false,
    preview = true,
    animation = true,
    animation_ms = 180,
    auto_pause = true,
    window = "current",
    split = { position = "right", width = 0 },
  },
  highlights = {
    added = "DiffAdd",
    removed = "DiffDelete",
    header = "Title",
    timeline_file = "Directory",
    timeline_time = "Comment",
    timeline_selected = "CursorLine",
    follow = "CursorLine",
    follow_label = "DiagnosticInfo",
    follow_cursor = "DiagnosticInfo",
  },
  keymaps = {
    toggle = "<leader>al",
    follow = "<leader>af",
    resume = "<leader>ar",
    next_edit = "]a",
    prev_edit = "[a",
    open_diff = "<CR>",
    close = "q",
    refresh = "R",
  },
  filter = {
    ignore_patterns = {
      "*.swp",
      "*.swo",
      "*~",
      "*.pyc",
      "__pycache__/**",
      ".git/**",
      "node_modules/**",
      ".DS_Store",
      "*.lock",
      "lazy-lock.json",
    },
  },
  agent_name = "agent",
}

---@type AgentLensOpts
M.options = {}

local function one_of(...)
  local allowed = { ... }
  return function(value)
    return vim.tbl_contains(allowed, value), "one of " .. table.concat(allowed, ", ")
  end
end
local function at_least(minimum)
  return function(value)
    return value % 1 == 0 and value >= minimum, "an integer >= " .. minimum
  end
end
-- Value checks beyond the type of the default, keyed by option path.
local rules = {
  debounce_ms = at_least(0),
  max_timeline_entries = at_least(1),
  timeline_position = one_of("right", "left", "bottom"),
  timeline_width = at_least(1),
  timeline_height = at_least(1),
  diff_layout = one_of("vertical", "horizontal"),
  ["timeline.view"] = one_of("files", "events"),
  ["timeline.filter"] = one_of("all", "reads", "edits"),
  ["reads.interval_ms"] = at_least(1),
  ["follow.animation_ms"] = at_least(0),
  ["follow.window"] = one_of("current", "split"),
  ["follow.split.position"] = one_of("left", "right"),
  ["follow.split.width"] = at_least(0),
}

--- Copy user options, dropping values whose type or range does not match the defaults.
---@param value any
---@param default any
---@param path string
---@param errors string[]
---@return any
local function sanitize(value, default, path, errors)
  if path == "watch_dir" then
    if type(value) ~= "string" or value == "" then
      errors[#errors + 1] = "watch_dir: expected a non-empty directory string"
      return nil
    end
    return value
  end
  if default == nil then
    return value
  end
  if value == false and path:match("^keymaps%.") then
    return value
  end
  if type(value) ~= type(default) then
    errors[#errors + 1] = string.format("%s: expected %s, got %s", path, type(default), type(value))
    return nil
  end
  if type(value) == "table" and vim.islist(default) then
    if not vim.islist(value) then
      errors[#errors + 1] = path .. ": expected a list of strings"
      return nil
    end
    for _, item in ipairs(value) do
      if type(item) ~= "string" then
        errors[#errors + 1] = path .. ": expected a list of strings"
        return nil
      end
    end
    return vim.deepcopy(value)
  end
  if type(value) == "table" and not vim.islist(default) then
    local result = {}
    for key, item in pairs(value) do
      local child = path == "" and tostring(key) or path .. "." .. tostring(key)
      result[key] = sanitize(item, default[key], child, errors)
    end
    return result
  end
  local valid, expected = true, nil
  if rules[path] then
    valid, expected = rules[path](value)
  end
  if not valid then
    errors[#errors + 1] =
      string.format("%s: expected %s, got %s", path, expected, vim.inspect(value))
    return nil
  end
  return value
end

---@param opts? AgentLensOpts
function M.setup(opts)
  local errors = {}
  local user = sanitize(opts or {}, M.defaults, "", errors)
  if #errors > 0 then
    vim.notify(
      "[agent-lens] Using defaults for invalid options:\n" .. table.concat(errors, "\n"),
      vim.log.levels.WARN
    )
  end
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, user or {})
end

return M
