--- Auto-command to register the health check.
vim.api.nvim_create_autocmd("User", {
  pattern = "LazyVimStarted",
  once = true,
  callback = function()
    -- Health check is auto-discovered from lua/agent-lens/health.lua
  end,
})
