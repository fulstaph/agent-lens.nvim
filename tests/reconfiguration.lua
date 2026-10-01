vim.opt.rtp:append(vim.fn.getcwd())
local lens = require("agent-lens")
local panel = require("agent-lens.panel")
local watcher = require("agent-lens.watcher")
local root = vim.fn.tempname()
local user_callback = function() end
local ok, err = xpcall(function()
  lens.setup({
    enabled = false,
    keymaps = {
      toggle = "<leader>zz",
      follow = "<leader>zx",
      resume = "<leader>zc",
      open_diff = "X",
    },
  })
  panel.open()
  local buffer = panel._buf
  vim.keymap.set("n", "<leader>zx", user_callback)
  vim.keymap.set("n", "<leader>unrelated", ":echo 'user'<CR>")
  lens.setup({
    enabled = false,
    keymaps = { toggle = false, follow = "", resume = false, open_diff = false },
  })
  assert(vim.fn.maparg("<leader>zz", "n") == "", "disabled global mapping is removed")
  assert(vim.fn.maparg("<leader>zc", "n") == "", "disabled resume mapping is removed")
  assert(vim.fn.maparg("<leader>zx", "n", false, true).callback == user_callback)
  assert(vim.fn.maparg("<leader>unrelated", "n") ~= "", "unrelated string mapping survives")
  vim.api.nvim_buf_call(buffer, function()
    assert(vim.fn.maparg("X", "n") == "", "disabled timeline mapping is removed")
    assert(vim.fn.maparg("j", "n") ~= "", "fixed timeline navigation remains")
  end)
  panel.close()
  lens.setup({ enabled = false, keymaps = { toggle = "<leader>old" } })
  local old_leader = vim.g.mapleader
  vim.g.mapleader = ","
  lens.setup({ enabled = false, keymaps = { toggle = "<leader>new" } })
  assert(vim.fn.maparg("\\old", "n") == "", "old expanded leader mapping is removed")
  assert(vim.fn.maparg(",new", "n") ~= "", "new leader mapping is installed")
  lens.setup({ enabled = false, keymaps = { toggle = false } })
  vim.g.mapleader = old_leader

  assert(not lens.start(root), "missing watch directory fails")
  assert(not watcher.is_running() and lens.status().watcher.state == "stopped")
  watcher.start(root, function() end)
  assert(not watcher.is_running(), "failed handles cannot report an active watcher")
end, debug.traceback)
panel.close()
lens.stop()
assert(ok, err)
print("reconfiguration and failed watcher OK")
vim.cmd("qa!")
