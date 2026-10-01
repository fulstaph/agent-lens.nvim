-- Complete socket records are bounded before JSON decoding.
vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false
local config = require("agent-lens.config")
local follow = require("agent-lens.follow")
local live = require("agent-lens.live")
local status = require("agent-lens.status")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
assert(vim.system({ "git", "init", "-q", root }):wait().code == 0)
config.setup({ enabled = false, follow = { enabled = true, animation = false } })
follow.setup(config.options.follow)
live.start(root)

local decode = vim.json.decode
local largest, receiving, closed = 0, false, false
vim.json.decode = function(text, ...)
  largest = math.max(largest, #text)
  return decode(text, ...)
end
local client = assert(vim.uv.new_pipe(false))
local ok, err = xpcall(function()
  vim.api.nvim_create_autocmd("User", {
    pattern = "AgentLensStatusChanged",
    callback = function()
      receiving = receiving or status.get().preview.state == "receiving"
    end,
  })
  local record = vim.json.encode({
    v = 1,
    kind = "preview",
    tool = "write",
    toolCallId = "oversized",
    path = "big.lua",
    sequence = 1,
    line = 1,
    agent = "pi",
    lines = { string.rep("x", 1024 * 1024 + 16) },
  })
  client:connect(live.directory(root) .. "/" .. vim.uv.os_getpid() .. ".sock", function(connect_err)
    assert(not connect_err, connect_err)
    client:read_start(function(_, chunk)
      if not chunk then
        closed = true
      end
    end)
    client:write(record .. "\n")
  end)
  assert(
    vim.wait(5000, function()
      return closed
    end, 10),
    "an oversized complete record closes the peer"
  )
  vim.wait(50)
  assert(largest <= 1024 * 1024, "oversized records are never decoded")
  assert(not receiving, "nothing was accepted from the oversized peer")
  print("live record bounds OK")
end, debug.traceback)
vim.json.decode = decode
if not client:is_closing() then
  client:close()
end
live.stop()
follow.clear()
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
vim.cmd("qa!")
