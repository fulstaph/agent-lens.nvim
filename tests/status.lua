vim.opt.rtp:append(vim.fn.getcwd())
local ok, err = pcall(function()
  require("agent-lens.config").setup({ enabled = false })
  local status = require("agent-lens.status")
  status.reset()
  local changes = 0
  vim.api.nvim_create_autocmd("User", {
    pattern = "AgentLensStatusChanged",
    callback = function()
      changes = changes + 1
    end,
  })
  vim.wait(20)
  changes = 0
  local fact = { phase = "drafting", path = "é 100%.lua", line = 2, lines = { "private" } }
  status.set("activity", fact)
  fact.path = "wrong"
  assert(status.get().activity.path == "é 100%.lua" and status.get().activity.lines == nil)
  local snapshot = status.get()
  snapshot.activity.path = "wrong"
  assert(status.get().activity.path == "é 100%.lua")
  status.set("follow", { control = "following", window = "current" })
  vim.wait(20)
  assert(changes == 1)
  status.set("activity", { phase = "drafting", path = "é 100%.lua", line = 2 })
  vim.wait(20)
  assert(changes == 1)
  assert(status.statusline():find("100%%.lua", 1, true))
  status.set("follow", { control = "paused", window = "current", reason = "navigation" })
  assert(status.compact():find("Paused", 1, true))
  status.set("preview", { state = "error", error = "bind failed" })
  status.set("preview", { state = "listening", peers = 0, last_valid_at = 4 })
  assert(status.get().preview.error == nil)
  vim.wo.statusline = "my status"
  vim.wo.winbar = "my bar"
  local win = vim.api.nvim_get_current_win()
  status.open()
  status.close()
  assert(vim.wo[win].statusline == "my status" and vim.wo[win].winbar == "my bar")
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.system({ "git", "init", root })
  local feed = require("agent-lens.read_events")
  feed.start(root)
  assert(status.get().metadata.state == "waiting")
  feed.stop()
  vim.wait(150)
  assert(status.get().metadata.state == "disabled")
  vim.fn.delete(root, "rf")
end)
if not ok then
  error(err)
end
print("status behavior OK")
vim.cmd("qa!")
