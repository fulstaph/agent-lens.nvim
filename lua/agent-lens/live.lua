--- Transient local-socket transport for live code previews. Nothing is logged.
local follow = require("agent-lens.follow")
local config = require("agent-lens.config")
local uv = vim.uv
local status = require("agent-lens.status")
local paths = require("agent-lens.paths")
local diff = require("agent-lens.diff")
local M = {}
local server
local socket_path
local peers = {}
local generation = 0
local MAX_BYTES = 1024 * 1024
local MAX_LINES = 20000
local MAX_PEERS = 8

--- Get the private socket directory shared with the Pi/OMP bridge.
---@param root string
---@return string|nil directory
---@return string|nil repository_root
function M.directory(root)
  local real_root = diff.git_root(root)
  local tmp = uv.fs_realpath("/tmp")
  if not real_root or not tmp then
    return nil
  end
  return tmp .. "/agent-lens-" .. uv.getuid() .. "-" .. vim.fn.sha256(real_root):sub(1, 16),
    real_root
end

local function validate_preview(root, repository_root, event)
  if
    type(event) ~= "table"
    or event.v ~= 1
    or event.kind ~= "preview"
    or (event.tool ~= "edit" and event.tool ~= "write")
    or not paths.call_id(event.toolCallId)
    or not paths.positive_integer(event.sequence)
    or not paths.positive_integer(event.line)
    or type(event.lines) ~= "table"
    or not vim.islist(event.lines)
    or #event.lines == 0
    or #event.lines > MAX_LINES
  then
    return false
  end
  local path = paths.rebase(root, repository_root, event.path, true)
  if not path then
    return false
  end
  local size = 0
  for _, line in ipairs(event.lines) do
    if type(line) ~= "string" or line:find("[%z\r\n]") then
      return false
    end
    size = size + #line + 1
    if size > MAX_BYTES then
      return false
    end
  end
  event.agent = paths.agent_name(event.agent) or config.options.agent_name
  event.path = path
  return true
end

local function close_peer(peer, drain)
  local state = peers[peer]
  if not state or state.closed then
    return
  end
  state.closed = true
  if not drain then
    peers[peer] = nil
  end
  peer:read_stop()
  if not peer:is_closing() then
    peer:close()
  end
  local function finish_close()
    if peers[peer] == state then
      if state.scheduled then
        vim.schedule(finish_close)
        return
      end
      peers[peer] = nil
    end
    if state.generation ~= generation then
      return
    end
    local count = vim.tbl_count(peers)
    local previous = status.get().preview
    status.set("preview", {
      state = count == 0 and "listening" or previous.state,
      peers = count,
      last_valid_at = previous.last_valid_at,
    })
    if state.call_id then
      local feed = require("agent-lens.read_events")
      if feed.root() == state.root then
        feed.poll()
      end
      follow.preview_disconnected(state.root, state.call_id)
    end
  end
  vim.schedule(finish_close)
end

--- Start a private, per-Neovim receiver for a repository.
---@param root string
function M.start(root)
  M.stop()
  if not follow.is_enabled() or config.options.follow.preview == false then
    return
  end
  local directory, repository_root = M.directory(root)
  if not directory then
    return
  end
  uv.fs_mkdir(directory, 448) -- 0700: only the current user can connect.
  local stat = uv.fs_lstat(directory)
  if not stat or stat.type ~= "directory" or stat.uid ~= uv.getuid() or stat.mode % 64 ~= 0 then
    status.set("preview", { state = "error", error = "Private directory unavailable" })
    vim.notify("[agent-lens] Cannot use private live-preview directory", vim.log.levels.WARN)
    return
  end
  socket_path = directory .. "/" .. uv.os_getpid() .. ".sock"
  server = uv.new_pipe(false)
  local bound = server and server:bind(socket_path)
  if not bound then
    M.stop()
    status.set("preview", { state = "error", error = "Socket bind failed" })
    vim.notify("[agent-lens] Cannot start live-preview socket", vim.log.levels.WARN)
    return
  end
  uv.fs_chmod(socket_path, 384) -- 0600
  local epoch = generation
  local listening = server:listen(MAX_PEERS, function(err)
    if err or epoch ~= generation then
      return
    end
    local peer = uv.new_pipe(false)
    if not peer then
      return
    end
    if not server:accept(peer) then
      peer:close()
      return
    end
    if vim.tbl_count(peers) >= MAX_PEERS then
      peer:close()
      return
    end
    local state = { root = root, generation = epoch, pending = "", scheduled = false }
    peers[peer] = state
    peer:read_start(function(read_err, chunk)
      if read_err or not chunk then
        close_peer(peer, not read_err)
        return
      end
      -- Earlier pending bytes hold no newline, so only the new chunk is scanned.
      local scan = #state.pending + 1
      state.pending = state.pending .. chunk
      -- Snapshots are complete states: a slow editor decodes only the newest one.
      local start, first, last = 1, nil, nil
      while true do
        local boundary = state.pending:find("\n", scan, true)
        if not boundary then
          break
        end
        -- Every record is bounded, including skipped ones, before anything is decoded.
        if boundary - start > MAX_BYTES then
          close_peer(peer)
          return
        end
        first, last, start = start, boundary - 1, boundary + 1
        scan = start
      end
      if first then
        state.latest = state.pending:sub(first, last)
        state.pending = state.pending:sub(start)
      end
      if #state.pending > MAX_BYTES then
        close_peer(peer)
        return
      end
      if state.latest and not state.scheduled then
        state.scheduled = true
        vim.schedule(function()
          state.scheduled = false
          local record = state.latest
          state.latest = nil
          if not record or epoch ~= generation or not peers[peer] then
            return
          end
          local ok, event = pcall(vim.json.decode, record)
          if ok and validate_preview(root, repository_root, event) then
            status.set(
              "preview",
              { state = "receiving", peers = vim.tbl_count(peers), last_valid_at = os.time() }
            )
            if follow.record_preview(root, event) then
              state.call_id = event.toolCallId
            end
          end
        end)
      end
    end)
  end)
  if not listening then
    M.stop()
    status.set("preview", { state = "error", error = "Socket listen failed" })
    vim.notify("[agent-lens] Cannot listen for live previews", vim.log.levels.WARN)
  else
    status.set("preview", { state = "listening", peers = 0 })
  end
end

--- Close receivers and remove this instance's socket.
function M.stop()
  generation = generation + 1
  status.set("preview", { state = "disabled" })
  local active = peers
  peers = {}
  for peer, state in pairs(active) do
    peer:read_stop()
    if not peer:is_closing() then
      peer:close()
    end
    if state.call_id then
      follow.preview_disconnected(state.root, state.call_id)
    end
  end
  if server then
    if not server:is_closing() then
      server:close()
    end
    server = nil
  end
  if socket_path then
    uv.fs_unlink(socket_path)
    uv.fs_rmdir(vim.fn.fnamemodify(socket_path, ":h"))
    socket_path = nil
  end
end

return M
