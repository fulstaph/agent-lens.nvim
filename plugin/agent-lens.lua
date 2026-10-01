-- Commands and keymaps are registered by require("agent-lens").setup().
-- :checkhealth agent-lens is discovered from lua/agent-lens/health.lua.
if vim.g.loaded_agent_lens then
  return
end
vim.g.loaded_agent_lens = true
