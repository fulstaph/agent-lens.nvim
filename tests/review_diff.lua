vim.opt.rtp:append(vim.fn.getcwd())
local diff = require("agent-lens.diff")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
local function git(...)
  local args = { "git", "-C", root }
  vim.list_extend(args, { ... })
  local r = vim.system(args):wait()
  assert(r.code == 0, r.stderr)
  return r.stdout
end
local ok, err = xpcall(function()
  git("init")
  assert(diff.git_root(root) == root, "repository discovery returns one canonical path")
  git("config", "user.email", "test@test")
  git("config", "user.name", "Test")
  local no_head, message = diff.review(root, "missing.lua")
  assert(no_head == nil and message:find("HEAD", 1, true), "unborn explicit baseline")
  for _, path in ipairs({ "partial.lua", "deleted.lua", "-flags %.lua", "π :special.lua" }) do
    vim.fn.writefile({ "one", "two", "three" }, root .. "/" .. path)
  end
  local f = assert(io.open(root .. "/binary", "wb"))
  f:write("a\0b")
  f:close()
  git("add", ".")
  git("commit", "-m", "initial")
  vim.fn.writefile({ "one", "three" }, root .. "/partial.lua")
  assert(diff.review(root, "partial.lua").status == "modified", "partial_deletion_is_modified")
  vim.fn.delete(root .. "/deleted.lua")
  assert(diff.review(root, "deleted.lua").status == "deleted")
  vim.fn.writefile({ "new" }, root .. "/untracked.lua")
  assert(diff.review(root, "untracked.lua").status == "added")
  for _, path in ipairs({ "-flags %.lua", "π :special.lua" }) do
    vim.fn.writefile({ "changed" }, root .. "/" .. path)
    assert(diff.review(root, path).stats.added == 1)
  end
  f = assert(io.open(root .. "/binary", "wb"))
  f:write("changed\0binary")
  f:close()
  local value, binary = diff.review(root, "binary")
  assert(value == nil and binary:lower():find("binary"))
  vim.uv.fs_symlink(root .. "/partial.lua", root .. "/link.lua")
  for _, path in ipairs({ "../escape", ".git/config", "link.lua" }) do
    assert(diff.review(root, path) == nil, "unsafe_review_targets")
  end
  local files = diff.changed_files(root)
  assert(
    vim.deep_equal(
      files,
      { "-flags %.lua", "binary", "deleted.lua", "partial.lua", "untracked.lua", "π :special.lua" }
    ),
    "sorted safe NUL paths"
  )
  local linked = vim.fn.tempname()
  git("worktree", "add", "--detach", linked, "HEAD")
  linked = vim.uv.fs_realpath(linked)
  vim.fn.writefile({ "linked" }, linked .. "/partial.lua")
  assert(diff.review(linked, "partial.lua").stats.added == 1, "worktree HEAD")
  git("worktree", "remove", "--force", linked)
  print("review diff behavior OK")
end, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
vim.cmd("qa!")
