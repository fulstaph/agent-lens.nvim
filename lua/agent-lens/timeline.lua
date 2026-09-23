--- Edit timeline data model.
--- Tracks file edits as they happen and maintains an ordered timeline.

local config = require("agent-lens.config")

local M = {}

---@class TimelineEntry
---@field id integer Unique entry ID
---@field timestamp integer Unix timestamp
---@field rel_path string Relative file path
---@field status "modified"|"added"|"deleted"|"renamed" File status
---@field stats {added: integer, removed: integer} Line counts
---@field agent string Agent name that made the edit
---@field diff_cached? table Cached FileDiff for this entry

---@type TimelineEntry[]
M.entries = {}

---@type integer
M._next_id = 1

---@type table<string, integer> Map from rel_path to most recent entry id
M._path_index = {}

--- Add a new entry to the timeline.
---@param entry_data {rel_path: string, status: string, stats: table, agent?: string, diff?: table}
---@return TimelineEntry
function M.add(entry_data)
  local entry = {
    id = M._next_id,
    timestamp = os.time(),
    rel_path = entry_data.rel_path,
    status = entry_data.status,
    stats = entry_data.stats or { added = 0, removed = 0 },
    agent = entry_data.agent or config.options.agent_name,
    diff_cached = entry_data.diff,
  }
  M._next_id = M._next_id + 1

  -- Trim old entries if over the limit
  while #M.entries >= config.options.max_timeline_entries do
    local removed = table.remove(M.entries, 1)
    if M._path_index[removed.rel_path] == removed.id then
      M._path_index[removed.rel_path] = nil
    end
  end

  M.entries[#M.entries + 1] = entry
  M._path_index[entry.rel_path] = entry.id

  return entry
end

--- Get all entries, newest first.
---@return TimelineEntry[]
function M.list()
  local result = {}
  for i = #M.entries, 1, -1 do
    result[#result + 1] = M.entries[i]
  end
  return result
end

--- Get the most recent entry for a file path.
---@param rel_path string
---@return TimelineEntry|nil
function M.latest_for_path(rel_path)
  local target_id = M._path_index[rel_path]
  if not target_id then
    return nil
  end
  for i = #M.entries, 1, -1 do
    if M.entries[i].id == target_id then
      return M.entries[i]
    end
  end
  return nil
end

--- Get entry by ID.
---@param id integer
---@return TimelineEntry|nil
function M.get(id)
  for i = #M.entries, 1, -1 do
    if M.entries[i].id == id then
      return M.entries[i]
    end
  end
  return nil
end

--- Clear the timeline.
function M.clear()
  M.entries = {}
  M._path_index = {}
  M._next_id = 1
end

--- Get total counts.
---@return {total: integer, files: integer, added: integer, removed: integer}
function M.summary()
  local files_set = {}
  local total_added, total_removed = 0, 0

  for _, entry in ipairs(M.entries) do
    files_set[entry.rel_path] = true
    total_added = total_added + entry.stats.added
    total_removed = total_removed + entry.stats.removed
  end

  local file_count = 0
  for _ in pairs(files_set) do
    file_count = file_count + 1
  end

  return {
    total = #M.entries,
    files = file_count,
    added = total_added,
    removed = total_removed,
  }
end

return M
