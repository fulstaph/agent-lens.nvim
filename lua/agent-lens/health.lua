--- Health check for agent-lens.nvim
local M = {}

function M.check()
  vim.health.start("agent-lens.nvim")

  -- Check Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 required")
  end

  -- Check vim.uv availability
  if vim.uv then
    vim.health.ok("vim.uv available")
  else
    vim.health.error("vim.uv not available — libuv bindings missing")
  end

  -- Check git
  if vim.fn.executable("git") == 1 then
    vim.health.ok("git executable found")
  else
    vim.health.error("git not found — required for diff computation")
  end

  -- Check if we're in a git repo
  local diff = require("agent-lens.diff")
  local root = diff.git_root()
  if root then
    vim.health.ok("Git repository detected: " .. root)
  else
    vim.health.warn(
      "Not currently in a git repository — agent-lens needs a repo to compute diffs"
    )
  end

  -- Check watcher state
  local watcher = require("agent-lens.watcher")
  if watcher.is_running() then
    vim.health.ok("File watcher is active")
  else
    vim.health.info("File watcher is not running — run :AgentLensStart")
  end
  local s = require("agent-lens.status").get()
  vim.health.info("Follow: " .. s.follow.control .. " / " .. s.follow.window)
  for _, section in ipairs({ "metadata", "preview" }) do
    local c = s[section]
    if c.state == "error" then
      vim.health.warn(section .. ": " .. (c.error or "error") .. "; retry :AgentLensStart")
    else
      vim.health.info(section .. ": " .. c.state .. "; details :AgentLensStatus")
    end
  end
end

return M
