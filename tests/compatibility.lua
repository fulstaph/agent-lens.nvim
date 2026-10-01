-- These exported helpers remain supported for integrations, even without core callers.
vim.opt.rtp:append(vim.fn.getcwd())
local config = require("agent-lens.config")
local timeline = require("agent-lens.timeline")
local diff = require("agent-lens.diff")
config.setup({ enabled = false, max_timeline_entries = 2 })
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
local function git(...)
  local result = vim.system(vim.list_extend({ "git", "-C", root }, { ... })):wait()
  assert(result.code == 0, result.stderr)
end
local ok, err = xpcall(function()
  git("init", "-q")
  vim.fn.writefile({ "old" }, root .. "/file.lua")
  git("add", ".")
  git("-c", "user.name=CI", "-c", "user.email=ci@example.test", "commit", "-qm", "fixture")
  vim.fn.writefile({ "new" }, root .. "/file.lua")
  local comparison = assert(diff.file_diff(root, "file.lua"))
  assert(vim.deep_equal(comparison, diff.review(root, "file.lua")))
  assert(vim.deep_equal(diff.status_summary(root), {
    { path = "file.lua", status = "modified", insertions = 1, deletions = 1 },
  }))
  local edit =
    timeline.add({ rel_path = "file.lua", status = "modified", stats = comparison.stats })
  local read = timeline.add({ rel_path = "file.lua", status = "read", kind = "read" })
  assert(timeline.latest_for_path("file.lua") == read)
  assert(
    timeline.latest_edit_for_path("file.lua") == edit,
    "reads do not hide the latest retained edit"
  )
  timeline.add({ rel_path = "another.lua", status = "modified" })
  assert(
    timeline.latest_for_path("file.lua") == read
      and timeline.latest_edit_for_path("file.lua") == nil
  )
  timeline.add({ rel_path = "last.lua", status = "modified" })
  assert(
    timeline.latest_for_path("file.lua") == nil,
    "trimmed paths do not leave stale index entries"
  )
  timeline.clear()
  assert(timeline.latest_for_path("last.lua") == nil)
end, debug.traceback)
vim.fn.delete(root, "rf")
assert(ok, err)
print("compatibility APIs OK")
vim.cmd("qa!")
