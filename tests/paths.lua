vim.opt.rtp:append(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/nested", "p")
root = vim.uv.fs_realpath(root)
vim.fn.writefile({ "safe" }, root .. "/safe.lua")
vim.uv.fs_symlink(root .. "/absent", root .. "/linked")
local ok, err = pcall(function()
  local paths = require("agent-lens.paths")
  assert(paths.resolve(root, "safe.lua", false) == root .. "/safe.lua")
  assert(paths.resolve(root, "nested/new.lua", true) == root .. "/nested/new.lua")
  assert(paths.resolve(root, "absent/new.lua", true) == root .. "/absent/new.lua")
  assert(paths.resolve(root, "new.lua", false) == nil)
  for _, path in ipairs({
    "../escape.lua",
    ".git/config",
    "/abs",
    "nested",
    "linked/new.lua",
    "safe.lua/child",
    "a\nb",
    "a//b",
    "./safe.lua",
  }) do
    assert(paths.resolve(root, path, true) == nil, path)
  end
  assert(paths.resolve(nil, "safe.lua", true) == nil)
  assert(paths.resolve({}, "safe.lua", true) == nil)
  assert(paths.resolve(root, {}, true) == nil)
  assert(paths.resolve(root, "safe.lua", "yes") == nil)
end)
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
print("paths behavior OK")
vim.cmd("qa!")
