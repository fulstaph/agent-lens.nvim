--- Optional Pi/OMP read events. Reads only metadata appended inside the active Git dir.
local config = require("agent-lens.config")
local timeline = require("agent-lens.timeline")

local M = {}
local uv = vim.uv or vim.loop
local timer
local log_path
local root
local offset = 0
local warned_open = false
local MAX_CHUNK = 65536

local function git_dir(project)
  local result = vim.fn.systemlist({ "git", "-C", project, "rev-parse", "--absolute-git-dir" })
  if vim.v.shell_error ~= 0 or #result == 0 then
    return nil
  end
  return result[1]
end

local function valid_path(path)
  if type(path) ~= "string" or path == "" or path:find("[%z\1-\31]") or path:sub(1, 1) == "/" then
    return false
  end
  for part in path:gmatch("[^/]+") do
    if part == "." or part == ".." then
      return false
    end
  end
  if path == ".git" or path:sub(1, 5) == ".git/" then
    return false
  end
  local real_root = uv.fs_realpath(root)
  local resolved = uv.fs_realpath(root .. "/" .. path)
  return real_root ~= nil
    and resolved ~= nil
    and resolved:sub(1, #real_root + 1) == real_root .. "/"
end

local function deliver(line)
  local ok, event = pcall(vim.json.decode, line)
  if
    not ok
    or type(event) ~= "table"
    or event.v ~= 1
    or event.kind ~= "read"
    or not valid_path(event.path)
  then
    return
  end
  local agent = type(event.agent) == "string"
      and event.agent:match("^[%w_%-]+$")
      and event.agent:sub(1, 32)
    or config.options.agent_name
  timeline.add({
    rel_path = event.path,
    kind = "read",
    status = "read",
    stats = { added = 0, removed = 0 },
    agent = agent,
  })
  local panel = require("agent-lens.panel")
  if panel.is_open() then
    panel.render()
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
  M.stop()
  local dir = git_dir(project)
  if not dir then
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
    vim.notify("[agent-lens] Could not start read tracking timer", vim.log.levels.ERROR)
    return
  end
  timer:start(
    config.options.reads.interval_ms,
    config.options.reads.interval_ms,
    vim.schedule_wrap(M.poll)
  )
end

function M.stop()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  log_path = nil
  root = nil
  offset = 0
  warned_open = false
end

function M.is_running()
  return timer ~= nil
end

function M.root()
  return root
end

return M
