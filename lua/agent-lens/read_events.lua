--- Optional Pi/OMP metadata feed for successful reads and live agent locations.
local config = require("agent-lens.config")
local timeline = require("agent-lens.timeline")
local inline = require("agent-lens.inline")
local follow = require("agent-lens.follow")
local paths = require("agent-lens.paths")
local diff = require("agent-lens.diff")

local status = require("agent-lens.status")
local generation = 0
local M = {}
local uv = vim.uv
local timer
local log_path
local root
local repository_root
local offset = 0
local warned_open = false
local MAX_CHUNK = 65536
local MAX_CALL_ID_BYTES = 256

local function git_dir(project)
  local result = vim.fn.systemlist({ "git", "-C", project, "rev-parse", "--absolute-git-dir" })
  if vim.v.shell_error ~= 0 or #result == 0 then
    return nil
  end
  return result[1]
end

local function agent_name(value)
  return type(value) == "string" and value:match("^[%w_%-]+$") and value:sub(1, 32)
    or config.options.agent_name
end

local function read_range(value)
  if
    type(value) ~= "table"
    or type(value.start) ~= "number"
    or type(value["end"]) ~= "number"
    or value.start % 1 ~= 0
    or value["end"] % 1 ~= 0
    or value.start < 1
    or value["end"] < value.start
  then
    return nil
  end
  return { start = value.start, ["end"] = value["end"] }
end

local function deliver_read(event)
  local path = paths.rebase(root, repository_root, event.path, false)
  if not path then
    return
  end
  status.set("metadata", { state = "received", last_valid_at = os.time() })
  local agent = agent_name(event.agent)
  local range = read_range(event.range)
  timeline.add({
    rel_path = path,
    kind = "read",
    status = "read",
    stats = { added = 0, removed = 0 },
    agent = agent,
    range = range,
  })
  inline.record_read(root, path, range, agent)
  local panel = require("agent-lens.panel")
  if panel.is_open() then
    panel.render()
  end
end

local function deliver_location(event)
  local phases = { start = true, progress = true, success = true, error = true }
  local tools = { read = true, edit = true, write = true }
  if
    not phases[event.phase]
    or not tools[event.tool]
    or type(event.toolCallId) ~= "string"
    or event.toolCallId == ""
    or #event.toolCallId > MAX_CALL_ID_BYTES
  then
    return
  end
  if event.phase == "progress" and event.tool ~= "edit" then
    return
  end
  if event.phase == "progress" then
    if type(event.sequence) ~= "number" or event.sequence % 1 ~= 0 or event.sequence < 1 then
      return
    end
  elseif event.sequence ~= nil then
    return
  end
  local line = event.line
  if line ~= nil and (type(line) ~= "number" or line % 1 ~= 0 or line < 1) then
    return
  end
  local path
  if event.phase ~= "error" then
    local allow_missing = (event.phase == "start" and event.tool == "write")
      or (
        event.tool == "edit"
        and (event.phase == "start" or event.phase == "progress" or event.phase == "success")
      )
    path = paths.rebase(root, repository_root, event.path, allow_missing)
    if not path then
      return
    end
  end
  status.set("metadata", { state = "received", last_valid_at = os.time() })
  follow.record_location(root, {
    call_id = event.toolCallId,
    phase = event.phase,
    tool = event.tool,
    path = path,
    line = line,
    agent = agent_name(event.agent),
    sequence = event.sequence,
  })
end

local function deliver(line)
  local ok, event = pcall(vim.json.decode, line)
  if not ok or type(event) ~= "table" or event.v ~= 1 then
    return
  end
  if event.kind == "read" then
    deliver_read(event)
  elseif event.kind == "location" then
    deliver_location(event)
  end
end

--- Consume complete JSONL records, leaving partial records for a later poll.
function M.poll()
  if not log_path then
    return
  end
  local file, err = io.open(log_path, "rb")
  if not file then
    if not warned_open and uv.fs_stat(log_path) then
      status.set("metadata", { state = "error", error = err })
      warned_open = true
      vim.notify("[agent-lens] Cannot read event log: " .. err, vim.log.levels.ERROR)
    end
    return
  end
  warned_open = false
  local size = file:seek("end")
  if size < offset then
    offset = 0
  end
  file:seek("set", offset)
  local chunk = file:read(MAX_CHUNK) or ""
  file:close()
  local consumed = 0
  for line in chunk:gmatch("([^\n]*)\n") do
    consumed = consumed + #line + 1
    deliver(line)
  end
  -- Drop an oversized incomplete record rather than rereading it forever.
  offset = offset + (consumed == 0 and #chunk == MAX_CHUNK and #chunk or consumed)
end

--- Start at the current end of the log; historical reads are not replayed.
---@param project string Absolute Git project root
function M.start(project)
  warned_open = false
  M.stop()
  local dir = git_dir(project)
  repository_root = diff.git_root(project)
  if not dir or not repository_root then
    repository_root = nil
    status.set("metadata", { state = "error", error = "Git repository unavailable" })
    vim.notify("[agent-lens] Read tracking requires a Git repository", vim.log.levels.WARN)
    return
  end
  root = project
  log_path = dir .. "/agent-lens/reads.jsonl"
  local stat = uv.fs_stat(log_path)
  offset = stat and stat.size or 0
  warned_open = false
  timer = uv.new_timer()
  if not timer then
    log_path = nil
    root = nil
    repository_root = nil
    vim.notify("[agent-lens] Could not start read tracking timer", vim.log.levels.ERROR)
    return
  end
  status.set("metadata", { state = "waiting" })
  local epoch = generation
  timer:start(
    config.options.reads.interval_ms,
    config.options.reads.interval_ms,
    vim.schedule_wrap(function()
      if epoch == generation then
        M.poll()
      end
    end)
  )
end

--- Cancel polling and invalidate callbacks from the previous feed.
function M.stop()
  generation = generation + 1
  status.set("metadata", { state = "disabled" })
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  log_path = nil
  root = nil
  repository_root = nil
  offset = 0
  warned_open = false
end

---@return boolean
function M.is_running()
  return timer ~= nil
end

---@return string|nil
function M.root()
  return root
end

return M
