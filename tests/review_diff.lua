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
  for _, path in ipairs({
    "partial.lua",
    "deleted.lua",
    "-flags %.lua",
    "π :special.lua",
    ":leading.lua",
  }) do
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
  for _, path in ipairs({ "-flags %.lua", "π :special.lua", ":leading.lua" }) do
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
    vim.deep_equal(files, {
      "-flags %.lua",
      ":leading.lua",
      "binary",
      "deleted.lua",
      "partial.lua",
      "untracked.lua",
      "π :special.lua",
    }),
    "sorted safe NUL paths"
  )
  local linked = vim.fn.tempname()
  git("worktree", "add", "--detach", linked, "HEAD")
  linked = vim.uv.fs_realpath(linked)
  vim.fn.writefile({ "linked" }, linked .. "/partial.lua")
  assert(diff.review(linked, "partial.lua").stats.added == 1, "worktree HEAD")
  git("worktree", "remove", "--force", linked)
  for _, path in ipairs({ "ordinary.txt", "Binary files notes.txt" }) do
    vim.fn.writefile(
      { path == "ordinary.txt" and "Binary files are skipped" or "ordinary line" },
      root .. "/" .. path
    )
    local text, reason = diff.review(root, path)
    assert(
      text and text.stats.added == 1,
      "ordinary text is reviewable: " .. path .. " " .. tostring(reason)
    )
  end
  vim.fn.writefile({ "forced.bin -diff" }, root .. "/.gitattributes")
  vim.fn.writefile({ "before" }, root .. "/forced.bin")
  git("add", ".gitattributes", "forced.bin")
  git("commit", "-m", "binary attribute")
  vim.fn.writefile({ "after" }, root .. "/forced.bin")
  local forced, reason = diff.review(root, "forced.bin")
  assert(forced == nil and reason:lower():find("binary"), "Git binary marker still rejected")
  vim.fn.mkdir(root .. "/nested", "p")
  for _, path in ipairs({ "a.lua", "b.lua", "deleted.lua" }) do
    vim.fn.writefile({ "before" }, root .. "/nested/" .. path)
  end
  git("add", "nested")
  git("commit", "-m", "subdirectory fixtures")
  vim.fn.writefile({ "after a" }, root .. "/nested/a.lua")
  vim.fn.writefile({ "after b" }, root .. "/nested/b.lua")
  vim.fn.writefile({ "new" }, root .. "/nested/new.lua")
  vim.fn.delete(root .. "/nested/deleted.lua")
  local nested = root .. "/nested"
  assert(
    vim.deep_equal(diff.changed_files(nested), { "a.lua", "b.lua", "deleted.lua", "new.lua" }),
    "changed paths stay relative to the watched subdirectory"
  )
  for _, path in ipairs(diff.changed_files(nested)) do
    assert(diff.review(nested, path), "enumerated subdirectory file can be reviewed: " .. path)
  end
  local review = require("agent-lens.diff_view")
  assert(review.open({ rel_path = "a.lua" }, { root = nested }))
  assert(review.navigate_file(1), "next-file review works below the repository root")
  assert(vim.wo.winbar:find("b.lua", 1, true))
  review.close()
  print("review diff behavior OK")
end, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
vim.cmd("qa!")
