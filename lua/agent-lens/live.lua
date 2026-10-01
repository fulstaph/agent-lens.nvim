--- Transient local-socket transport for live code previews. Nothing is logged.
local follow = require("agent-lens.follow")
local config = require("agent-lens.config")
local uv = vim.uv
local status = require("agent-lens.status")
local M = {}
local server
local socket_path
local peers = {}
local generation = 0
local MAX_BYTES = 1024 * 1024
local MAX_LINES = 20000

--- Get the private socket directory shared with the Pi/OMP bridge.
---@param root string
---@return string|nil
function M.directory(root)
  local real_root = uv.fs_realpath(root)
  local tmp = uv.fs_realpath("/tmp")
  if not real_root or not tmp then
    return nil
  end
  return tmp .. "/agent-lens-" .. uv.getuid() .. "-" .. vim.fn.sha256(real_root):sub(1, 16)
end

local function valid_preview(root, event)
  if
    type(event) ~= "table"
    or event.v ~= 1
    or event.kind ~= "preview"
    or (event.tool ~= "edit" and event.tool ~= "write")
    or type(event.toolCallId) ~= "string"
    or #event.toolCallId == 0
    or #event.toolCallId > 256
    or type(event.sequence) ~= "number"
    or event.sequence % 1 ~= 0
    or event.sequence < 1
    or type(event.line) ~= "number"
    or event.line % 1 ~= 0
    or event.line < 1
    or type(event.lines) ~= "table"
    or not vim.islist(event.lines)
    or #event.lines == 0
    or #event.lines > MAX_LINES
    or not follow.target_path(root, event.path, true)
  then
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
  event.agent = type(event.agent) == "string"
      and event.agent:match("^[%w_%-]+$")
      and event.agent:sub(1, 32)
    or config.options.agent_name
  return true
end

local function close_peer(peer)
  if not peers[peer] then
    return
  end
  local state = peers[peer]
  peers[peer] = nil
  peer:read_stop()
  if not peer:is_closing() then
    peer:close()
  end
  vim.schedule(function()
    if state.generation == generation then
      local count = 0
      for _ in pairs(peers) do
        count = count + 1
      end
      local previous = status.get().preview
      status.set("preview", {
        state = count == 0 and "listening" or previous.state,
        peers = count,
        last_valid_at = previous.last_valid_at,
      })
    end
    if state.generation == generation and state.call_id then
      follow.preview_disconnected(state.root, state.call_id)
    end
  end)
end

--- Start a private, per-Neovim receiver for a repository.
---@param root string
function M.start(root)
  M.stop()
  if not follow.is_enabled() or config.options.follow.preview == false then
    return
  end
  local directory = M.directory(root)
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
  local listening = server:listen(8, function(err)
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
    local count = 0
    for _ in pairs(peers) do
      count = count + 1
    end
    if count >= 8 then
      peer:close()
      return
    end
    local state = { root = root, generation = epoch, pending = "", queued = 0 }
    peers[peer] = state
    peer:read_start(function(read_err, chunk)
      if read_err or not chunk then
        close_peer(peer)
        return
      end
      state.pending = state.pending .. chunk
      if #state.pending > MAX_BYTES then
        close_peer(peer)
        return
      end
      while true do
        local boundary = state.pending:find("\n", 1, true)
        if not boundary then
          break
        end
        local record = state.pending:sub(1, boundary - 1)
        state.pending = state.pending:sub(boundary + 1)
        state.queued = state.queued + #record
        if state.queued > MAX_BYTES then
          close_peer(peer)
          return
        end
        vim.schedule(function()
          state.queued = state.queued - #record
          if epoch ~= generation or not peers[peer] then
            return
          end
          local ok, event = pcall(vim.json.decode, record)
          if ok and valid_preview(root, event) then
            local count = 0
            for _ in pairs(peers) do
              count = count + 1
            end
            status.set("preview", { state = "receiving", peers = count, last_valid_at = os.time() })
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
