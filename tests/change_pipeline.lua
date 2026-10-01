-- Drive filesystem callbacks deterministically while Git runs through real coroutines.
vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false
local cwd = vim.fn.getcwd()
local lens = require("agent-lens")
local watcher = require("agent-lens.watcher")
local timeline = require("agent-lens.timeline")
local diff = require("agent-lens.diff")
local review = require("agent-lens.diff_view")
local panel = require("agent-lens.panel")
local roots = {}
local system = vim.system
local async = diff.async
local captured, running
watcher.start = function(_, callback)
  captured, running = callback, true
end
watcher.stop = function()
  running = false
end
watcher.is_running = function()
  return running == true
end
local function fixture(label)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = vim.uv.fs_realpath(root)
  roots[#roots + 1] = root
  local function git(...)
    local result = system(vim.list_extend({ "git", "-C", root }, { ... })):wait()
    assert(result.code == 0, result.stderr)
  end
  git("init", "-q")
  vim.fn.writefile({ label .. " old" }, root .. "/a.lua")
  vim.fn.writefile({ "one", "two" }, root .. "/gone.txt")
  git("add", ".")
  git("-c", "user.name=CI", "-c", "user.email=ci@example.test", "commit", "-qm", "fixture")
  return root
end
local ok, err = xpcall(function()
  local root, other = fixture("repository A"), fixture("repository B")
  lens.setup({ enabled = false })
  assert(lens.start(root))
  assert(not lens.start(root .. "/missing"), "an invalid restart fails")
  assert(lens._root == root and watcher.is_running(), "invalid restarts keep the active context")
  vim.fn.delete(root .. "/gone.txt")
  captured("gone.txt", { rename = true, deleted = true })
  assert(vim.wait(3000, function()
    return timeline.latest_for_path("gone.txt") ~= nil
  end, 10))
  local deletion = timeline.latest_for_path("gone.txt")
  assert(deletion.status == "deleted" and deletion.stats.removed == 2)
  assert(timeline.summary().removed == 2, "deleted-file statistics reach the panel header")

  lens.setup({ enabled = false, auto_open_diff = true })
  assert(lens.start(root))
  vim.fn.writefile({ "repository A new" }, root .. "/a.lua")
  local blocking = 0
  vim.system = function(command, options, callback)
    if command[1] == "git" and not callback then
      blocking = blocking + 1
    end
    return system(command, options, callback)
  end
  captured("a.lua", { change = true })
  assert(vim.wait(3000, review.is_open, 10), "auto-open completes")
  vim.system = system
  assert(blocking == 0, "auto-open must not run synchronous Git on the event path")
  assert(
    vim.api.nvim_get_current_line() == "repository A new",
    "auto-open renders fetched contents"
  )
  assert(timeline.latest_for_path("a.lua").diff_cached == nil, "timeline retains metadata only")
  review.close()

  panel.open()
  lens.stop()
  vim.fn.writefile({ "repository B new" }, other .. "/a.lua")
  vim.fn.chdir(other)
  assert(lens.show_diff(), "retained timeline remains reviewable after stop")
  assert(
    vim.api.nvim_get_current_line() == "repository A new",
    "review stays bound to the watched root"
  )
  review.close()
  assert(lens.preview(), "preview also keeps its stopped-root context")
  assert(
    table
      .concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      :find("repository A new", 1, true)
  )
  review.close()
  panel.close()
  vim.fn.chdir(cwd)

  assert(lens.start(root))
  local delayed
  diff.async = function(fn, callback, ...)
    if fn == diff.ignored then
      return async(fn, callback, ...)
    end
    async(fn, function(snapshot)
      delayed = function()
        callback(snapshot)
      end
    end, ...)
  end
  captured("a.lua", { change = true })
  assert(vim.wait(3000, function()
    return delayed ~= nil
  end, 10))
  local retained = #timeline.entries
  lens.stop()
  delayed()
  assert(
    not review.is_open() and #timeline.entries == retained,
    "stopped auto-open cannot restore UI"
  )
end, debug.traceback)
vim.system = system
diff.async = async
review.close()
panel.close()
lens.stop()
vim.fn.chdir(cwd)
for _, root in ipairs(roots) do
  vim.fn.delete(root, "rf")
end
assert(ok, err)
print("change pipeline regressions OK")
vim.cmd("qa!")
