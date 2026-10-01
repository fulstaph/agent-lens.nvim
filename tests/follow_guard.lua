-- A failing render must not leave Follow's input provenance suppressed.
vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false
local config = require("agent-lens.config")
local follow = require("agent-lens.follow")
local motion = require("agent-lens.motion")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
vim.fn.writefile({ "one", "two", "three" }, root .. "/file.lua")

local ok, err = xpcall(function()
  config.setup({ enabled = false, follow = { enabled = true, animation = false } })
  follow.setup(config.options.follow)
  local view = motion.view
  motion.view = function()
    error("frame failed")
  end
  local rendered = pcall(follow.record_preview, root, {
    toolCallId = "call",
    tool = "edit",
    path = "file.lua",
    line = 2,
    sequence = 1,
    agent = "pi",
    lines = { "one", "draft", "three" },
  })
  motion.view = view
  assert(not rendered, "render errors still surface")
  assert(follow.state().control == "following")
  vim.api.nvim_feedkeys("k", "xt", false)
  assert(follow.state().control == "paused", "navigation pauses after a failed render")
  print("follow guard OK")
end, debug.traceback)
follow.stop()
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
vim.cmd("qa!")
