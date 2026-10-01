--- Track plugin mappings so reconfiguration removes only bindings still owned here.
local M = {}
local scopes = {}
vim.api.nvim_create_autocmd("BufWipeout", {
  group = vim.api.nvim_create_augroup("AgentLensKeymapCleanup", { clear = true }),
  callback = function(event)
    scopes[event.buf] = nil
  end,
})

local function mappings(buffer)
  if buffer == 0 then
    return vim.api.nvim_get_keymap("n")
  end
  return vim.api.nvim_buf_is_valid(buffer) and vim.api.nvim_buf_get_keymap(buffer, "n") or {}
end

--- Remove registered mappings, preserving user replacements.
---@param buffer? integer Omit for global mappings
function M.clear(buffer)
  buffer = buffer or 0
  local owned = scopes[buffer] or {}
  for _, mapping in ipairs(mappings(buffer)) do
    if owned[mapping.lhs] and owned[mapping.lhs] == mapping.callback then
      pcall(vim.keymap.del, "n", mapping.lhs, buffer ~= 0 and { buffer = buffer } or {})
    end
  end
  scopes[buffer] = nil
end

--- Install and remember one normal-mode mapping.
---@param lhs string|false
---@param action function
---@param opts? {buffer?: integer, desc?: string, silent?: boolean, nowait?: boolean}
function M.set(lhs, action, opts)
  if not lhs or lhs == "" then
    return
  end
  opts = opts or {}
  local buffer = opts.buffer or 0
  -- Each binding gets a unique callback, including aliases of the same action.
  local callback = function(...)
    return action(...)
  end
  vim.keymap.set("n", lhs, callback, opts)
  scopes[buffer] = scopes[buffer] or {}
  for _, mapping in ipairs(mappings(buffer)) do
    if mapping.callback == callback then
      scopes[buffer][mapping.lhs] = callback
      break
    end
  end
end

return M
