--- Pure timeline projection: identities survive arrivals and reordering.
local M = {}
---@class PanelOptions
---@field view 'files'|'events'
---@field filter 'all'|'reads'|'edits'
---@field unread_only boolean
---@field expanded table<string, boolean>
---@class PanelRow
---@field key string
---@field kind 'file'|'event'
---@field path string
---@field entry TimelineEntry
---@field event_ids integer[]
---@field depth integer
---@field reads integer
---@field edits integer
---@field unread integer
---@field stats? {added: integer, removed: integer}
local function matches(entry, filter)
  return filter == "all" or (filter == "reads") == (entry.kind == "read")
end
local function event_row(entry, depth, unread)
  return {
    key = "event:" .. entry.id,
    kind = "event",
    path = entry.rel_path,
    entry = entry,
    event_ids = { entry.id },
    depth = depth,
    reads = entry.kind == "read" and 1 or 0,
    edits = entry.kind == "read" and 0 or 1,
    unread = unread[entry.id] and 1 or 0,
    stats = entry.kind ~= "read" and entry.stats or nil,
  }
end

-- Entries are newest first, so groups retain the latest matching edit's stats.
local function group_by_file(entries, filter, unread)
  local groups, ordered = {}, {}
  for _, entry in ipairs(entries) do
    if matches(entry, filter) then
      local group = groups[entry.rel_path]
      if not group then
        group = {
          key = "file:" .. entry.rel_path,
          kind = "file",
          path = entry.rel_path,
          entry = entry,
          event_ids = {},
          depth = 0,
          reads = 0,
          edits = 0,
          unread = 0,
          children = {},
        }
        groups[entry.rel_path] = group
        ordered[#ordered + 1] = group
      end
      group.event_ids[#group.event_ids + 1] = entry.id
      group.children[#group.children + 1] = entry
      local category = entry.kind == "read" and "reads" or "edits"
      group[category] = group[category] + 1
      if category == "edits" and not group.stats then
        group.stats = entry.stats
        group.entry = entry
      end
      if unread[entry.id] then
        group.unread = group.unread + 1
      end
    end
  end
  return ordered
end

--- Project retained events, newest first, into stable file/event rows.
---@param entries TimelineEntry[]
---@param opts PanelOptions
---@param unread table<integer, boolean>
---@return PanelRow[]
function M.project(entries, opts, unread)
  local ordered = vim.list_extend({}, entries)
  table.sort(ordered, function(a, b)
    return a.id > b.id
  end)
  local rows = {}
  if opts.view == "events" then
    for _, entry in ipairs(ordered) do
      if matches(entry, opts.filter) and (not opts.unread_only or unread[entry.id]) then
        rows[#rows + 1] = event_row(entry, 0, unread)
      end
    end
    return rows
  end
  for _, group in ipairs(group_by_file(ordered, opts.filter, unread)) do
    if not opts.unread_only or group.unread > 0 then
      rows[#rows + 1] = group
      if opts.expanded[group.path] then
        for _, entry in ipairs(group.children) do
          if not opts.unread_only or unread[entry.id] then
            rows[#rows + 1] = event_row(entry, 1, unread)
          end
        end
      end
    end
  end
  return rows
end
--- Retain selection, else its group, else nearest surviving previous row.
---@param rows PanelRow[]
---@param previous_rows PanelRow[]
---@param previous_key? string
---@return string|nil
function M.select(rows, previous_rows, previous_key)
  local visible = {}
  for _, r in ipairs(rows) do
    visible[r.key] = true
  end
  if previous_key and visible[previous_key] then
    return previous_key
  end
  local old_index, old_path
  for i, r in ipairs(previous_rows) do
    if r.key == previous_key then
      old_index = i
      old_path = r.path
      break
    end
  end
  if old_path and visible["file:" .. old_path] then
    return "file:" .. old_path
  end
  if old_index then
    for distance = 1, #previous_rows do
      for _, i in ipairs({ old_index + distance, old_index - distance }) do
        local r = previous_rows[i]
        if r and visible[r.key] then
          return r.key
        end
      end
    end
  end
  return rows[1] and rows[1].key or nil
end
return M
