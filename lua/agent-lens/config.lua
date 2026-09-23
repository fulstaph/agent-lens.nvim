---@class AgentLensHighlights
---@field added? string Highlight group for added lines
---@field removed? string Highlight group for removed lines
---@field changed? string Highlight group for changed lines
---@field header? string Highlight group for diff headers
---@field timeline_file? string Highlight group for filenames in timeline
---@field timeline_time? string Highlight group for timestamps in timeline
---@field timeline_agent? string Highlight group for agent name in timeline
---@field timeline_selected? string Highlight group for selected timeline entry

---@class AgentLensKeymaps
---@field toggle? string Toggle the timeline panel
---@field next_edit? string Jump to next edit in timeline
---@field prev_edit? string Jump to previous edit in timeline
---@field open_diff? string Open diff for selected edit
---@field close? string Close all agent-lens windows
---@field accept? string Accept (no-op, informational)
---@field refresh? string Force refresh the file watcher

---@class AgentLensFilter
---@field ignore_patterns? string[] Glob patterns to ignore
---@field min_change_bytes? integer Minimum bytes changed to show in timeline

---@class AgentLensOpts
---@field enabled? boolean Auto-start watching on setup
---@field watch_dir? string Directory to watch (default: cwd / git root)
---@field diff_source? "git" | "snapshot" How to compute diffs
---@field debounce_ms? integer Debounce file change events
---@field max_timeline_entries? integer Max entries to keep in timeline
---@field timeline_position? "right" | "left" | "bottom" Panel position
---@field timeline_width? integer Width of timeline panel (for left/right)
---@field timeline_height? integer Height of timeline panel (for bottom)
---@field diff_layout? "vertical" | "horizontal" Diff split direction
---@field auto_open_diff? boolean Auto-open diff on new edit
---@field highlights? AgentLensHighlights
---@field keymaps? AgentLensKeymaps
---@field filter? AgentLensFilter
---@field agent_name? string Display name for the agent

local M = {}

---@type AgentLensOpts
M.defaults = {
  enabled = true,
  watch_dir = nil, -- auto-detect git root or cwd
  diff_source = "git",
  debounce_ms = 150,
  max_timeline_entries = 200,
  timeline_position = "right",
  timeline_width = 42,
  timeline_height = 15,
  diff_layout = "vertical",
  auto_open_diff = false,
  highlights = {
    added = "DiffAdd",
    removed = "DiffDelete",
    changed = "DiffChange",
    header = "Title",
    timeline_file = "Directory",
    timeline_time = "Comment",
    timeline_agent = "Keyword",
    timeline_selected = "CursorLine",
  },
  keymaps = {
    toggle = "<leader>al",
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
    min_change_bytes = 1,
  },
  agent_name = "agent",
}

---@type AgentLensOpts
M.options = {}

---@param opts? AgentLensOpts
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
