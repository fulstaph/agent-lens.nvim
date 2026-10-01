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
local function matches(e, filter)
  return filter == "all" or (filter == "reads") == (e.kind == "read")
end
local function event_row(e, depth, unread)
  return {
    key = "event:" .. e.id,
    kind = "event",
    path = e.rel_path,
    entry = e,
    event_ids = { e.id },
    depth = depth,
    reads = e.kind == "read" and 1 or 0,
    edits = e.kind == "read" and 0 or 1,
    unread = unread[e.id] and 1 or 0,
    stats = e.kind ~= "read" and e.stats or nil,
  }
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
  local rows, groups, group_order = {}, {}, {}
  for _, e in ipairs(ordered) do
    if matches(e, opts.filter) then
      if opts.view == "events" then
        if not opts.unread_only or unread[e.id] then
          rows[#rows + 1] = event_row(e, 0, unread)
        end
      else
        local g = groups[e.rel_path]
        if not g then
          g = {
            key = "file:" .. e.rel_path,
            kind = "file",
            path = e.rel_path,
            entry = e,
            event_ids = {},
            depth = 0,
            reads = 0,
            edits = 0,
            unread = 0,
            children = {},
          }
          groups[e.rel_path] = g
          group_order[#group_order + 1] = g
        end
        g.event_ids[#g.event_ids + 1] = e.id
        g.children[#g.children + 1] = e
        if e.kind == "read" then
          g.reads = g.reads + 1
        else
          g.edits = g.edits + 1
          if not g.stats then
            g.stats = e.stats
            g.entry = e
          end
        end
        if unread[e.id] then
          g.unread = g.unread + 1
        end
      end
    end
  end
  for _, g in ipairs(group_order) do
    if not opts.unread_only or g.unread > 0 then
      rows[#rows + 1] = g
      if opts.expanded[g.path] then
        for _, e in ipairs(g.children) do
          if not opts.unread_only or unread[e.id] then
            rows[#rows + 1] = event_row(e, 1, unread)
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
