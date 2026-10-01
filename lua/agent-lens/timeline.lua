--- Filesystem edits and optional agent-reported reads in arrival order.

local config = require("agent-lens.config")

local M = {}
local seen = {}

---@class TimelineEntry
---@field id integer Unique entry ID
---@field timestamp integer Unix timestamp
---@field rel_path string Relative file path
---@field status "modified"|"added"|"deleted"|"renamed"|"read" File status
---@field range? {start: integer, ["end"]: integer}
---@field kind? "read" Read entries do not have a diff
---@field stats {added: integer, removed: integer} Line counts
---@field agent string Agent name that made the edit
---@field diff_cached? table Cached FileDiff for this entry

---@type TimelineEntry[]
M.entries = {}

---@type integer
M._next_id = 1

---@type table<string, TimelineEntry> Map from rel_path to most recent entry
M._path_index = {}

--- Add a new entry to the timeline.
---@param entry_data {rel_path: string, status: string, kind?: string, stats?: table, agent?: string, diff?: table, range?: table}
---@return TimelineEntry
function M.add(entry_data)
  local entry = {
    id = M._next_id,
    timestamp = os.time(),
    rel_path = entry_data.rel_path,
    kind = entry_data.kind,
    status = entry_data.status,
    range = entry_data.range and vim.deepcopy(entry_data.range) or nil,
    stats = entry_data.stats and vim.deepcopy(entry_data.stats) or { added = 0, removed = 0 },
    agent = entry_data.agent or config.options.agent_name,
    diff_cached = entry_data.diff,
  }
  M._next_id = M._next_id + 1

  -- Trim old entries if over the limit
  while #M.entries >= config.options.max_timeline_entries do
    local removed = table.remove(M.entries, 1)
    seen[removed.id] = nil
    if M._path_index[removed.rel_path] == removed then
      M._path_index[removed.rel_path] = nil
    end
  end

  M.entries[#M.entries + 1] = entry
  M._path_index[entry.rel_path] = entry

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
  return M._path_index[rel_path]
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
  seen = {}
end

--- Get the latest retained edit snapshot, independent of reads.
---@param path string
---@return TimelineEntry|nil
function M.latest_edit_for_path(path)
  for i = #M.entries, 1, -1 do
    local e = M.entries[i]
    if e.rel_path == path and e.kind ~= "read" then
      return e
    end
  end
end
--- Acknowledge retained IDs only.
---@param ids integer[]
function M.acknowledge(ids)
  for _, id in ipairs(ids) do
    if M.get(id) then
      seen[id] = true
    end
  end
end
--- Mark the retained feed as seen.
function M.mark_all_seen()
  for _, e in ipairs(M.entries) do
    seen[e.id] = true
  end
end
--- Return copied unacknowledged retained IDs.
---@return table<integer, boolean>
function M.unread_ids()
  local ids = {}
  for _, e in ipairs(M.entries) do
    if not seen[e.id] then
      ids[e.id] = true
    end
  end
  return ids
end
--- Retained latest comparisons, not a sum of repeated event snapshots.
---@return {total: integer, files: integer, added: integer, removed: integer, reads: integer, edits: integer, unread: integer}
function M.summary()
  local latest, files = {}, {}
  local result =
    { total = #M.entries, files = 0, added = 0, removed = 0, reads = 0, edits = 0, unread = 0 }
  for _, e in ipairs(M.entries) do
    files[e.rel_path] = true
    if e.kind == "read" then
      result.reads = result.reads + 1
    else
      result.edits = result.edits + 1
      latest[e.rel_path] = e
    end
    if not seen[e.id] then
      result.unread = result.unread + 1
    end
  end
  for _ in pairs(files) do
    result.files = result.files + 1
  end
  for _, e in pairs(latest) do
    result.added = result.added + e.stats.added
    result.removed = result.removed + e.stats.removed
  end
  return result
end
return M
