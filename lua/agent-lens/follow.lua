--- Follow control, correlation and one latest pending snapshot.
local config = require("agent-lens.config")
local status = require("agent-lens.status")
local view = require("agent-lens.follow_view")
local M = {}
---@class FollowTarget
---@field root string
---@field call_id string
---@field phase string
---@field tool string
---@field path? string
---@field line? integer
---@field agent? string
---@field sequence? integer
local control = "off"
local reason
local window = "current"
local target
local pending
local active_call_id
local finished = {}
local order = {}
local phases = { progress = "drafting", start = "applying", success = "settled", error = "failed" }
local function publish()
  status.set("follow", { control = control, window = window, reason = reason })
  status.set("activity", target and {
    phase = target.tool == "read" and target.phase == "start" and "reading" or phases[target.phase],
    tool = target.tool,
    path = target.path,
    line = target.line,
    call_id = target.call_id,
  } or { phase = "idle" })
end
local function render()
  publish()
  if control ~= "following" or not target or not target.path then
    return false
  end
  return view.render(target, pending)
end
local function finish(id)
  if finished[id] then
    return
  end
  finished[id] = true
  order[#order + 1] = id
  if #order > 256 then
    finished[table.remove(order, 1)] = nil
  end
end
--- Compatibility delegate to the shared trust boundary.
---@param root string
---@param path string
---@param allow_missing? boolean
---@return string|nil
function M.target_path(root, path, allow_missing)
  return require("agent-lens.paths").resolve(root, path, allow_missing)
end
--- Configure Follow and its view.
---@param opts table
function M.setup(opts)
  control = opts.enabled and "following" or "off"
  window = opts.window or "current"
  reason = nil
  target = nil
  pending = nil
  active_call_id = nil
  finished = {}
  order = {}
  view.setup(opts, function(why, insert)
    if control == "off" then
      return
    end
    M.pause(why)
    if insert and not view.handoff() then
      reason = "Cannot load source; resume to retry"
      vim.cmd("stopinsert")
      publish()
    end
  end)
  publish()
end
--- Pause without stopping incoming metadata or snapshots.
---@param why? string
---@return boolean
function M.pause(why)
  if control == "off" then
    return false
  end
  control = "paused"
  reason = why or "manual"
  view.freeze()
  publish()
  return true
end
--- Resume the newest validated target; a failed handoff stays paused.
---@return boolean
function M.resume()
  control = "following"
  reason = nil
  if target and target.path and not render() then
    control = "paused"
    reason = reason or "Target unavailable or editor protected"
    view.freeze()
    publish()
    return false
  end
  publish()
  return true
end
--- Get copied control state.
---@return FollowState
function M.state()
  return { control = control, window = window, reason = reason }
end
--- Receive one bounded validated draft; paused views are untouched.
---@param root string
---@param event table
---@return boolean
function M.record_preview(root, event)
  if
    control == "off"
    or config.options.follow.preview == false
    or finished[event.toolCallId]
    or not M.target_path(root, event.path, true)
    or (target and target.phase == "start" and target.call_id ~= event.toolCallId)
    or (pending and pending.toolCallId == event.toolCallId and event.sequence <= pending.sequence)
  then
    return false
  end
  pending = vim.deepcopy(event)
  active_call_id = event.toolCallId
  target = {
    root = root,
    call_id = event.toolCallId,
    phase = target and target.call_id == event.toolCallId and target.phase == "start" and "start"
      or "progress",
    tool = event.tool,
    path = event.path,
    line = event.line,
    agent = event.agent,
  }
  render()
  return true
end
--- Discard speculative content on an unfinished connection closure.
---@param root string
---@param call_id string
function M.preview_disconnected(root, call_id)
  if
    not target
    or target.root ~= root
    or target.call_id ~= call_id
    or target.phase == "success"
  then
    return
  end
  finish(call_id)
  pending = nil
  active_call_id = nil
  target = nil
  view.clear()
  publish()
end
--- Receive validated, correlated lifecycle metadata.
---@param root string
---@param location table
function M.record_location(root, location)
  if finished[location.call_id] then
    return
  end
  if location.phase == "progress" then
    if target and target.phase == "start" then
      return
    end
    if
      target
      and target.call_id == location.call_id
      and target.sequence
      and location.sequence <= target.sequence
    then
      return
    end
  end
  if location.phase == "start" or location.phase == "progress" then
    if pending and pending.toolCallId ~= location.call_id then
      pending = nil
    end
    local previous = target
    active_call_id = location.call_id
    target = vim.tbl_extend("force", {}, location, { root = root })
    if previous and previous.call_id == location.call_id and previous.path == location.path then
      target.line = location.line or previous.line
    end
    render()
    return
  end
  finish(location.call_id)
  if active_call_id ~= location.call_id then
    return
  end
  local previous = target
  local preview_line = pending and pending.line
  active_call_id = nil
  pending = nil
  target = vim.tbl_extend("force", {}, location, {
    root = root,
    path = location.path or (previous and previous.path),
    line = preview_line or location.line or (previous and previous.line),
  })
  if location.phase == "error" then
    view.clear()
    target.path = nil
    publish()
    return
  end
  render()
end
--- Reload only the active target.
---@param root string
---@param path string
function M.file_changed(root, path)
  if target and target.root == root and target.path == path then
    render()
  end
end
--- Toggle opt-in Follow control.
---@return boolean
function M.toggle()
  if control == "off" then
    M.resume()
  else
    M.stop()
  end
  return M.is_enabled()
end
---@return boolean
function M.is_enabled()
  return control ~= "off"
end
--- Reset pending activity while retaining enablement.
function M.clear()
  view.clear()
  target = nil
  pending = nil
  active_call_id = nil
  finished = {}
  order = {}
  reason = nil
  if control ~= "off" then
    control = "following"
  end
  publish()
end
--- Stop Follow and release owned UI.
function M.stop()
  local settled, recent = finished, order
  M.clear()
  finished, order = settled, recent
  control = "off"
  publish()
end
return M
