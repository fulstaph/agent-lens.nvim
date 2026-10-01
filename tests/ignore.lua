-- Ignore globs, Git ignore rules, and non-blocking watcher diffs.
vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false

local config = require("agent-lens.config")
local diff = require("agent-lens.diff")
config.setup({ enabled = false })

-- Glob punctuation is literal; wildcards and classes stay within one segment.
local watcher = require("agent-lens.watcher")
for _, case in ipairs({
  { "lazy-lock.json", "lazy-lock.json", true },
  { "lazy-lock.json", "lazylock.json", false },
  { "foo(1).txt", "foo(1).txt", true },
  { "a+b%.c", "a+b%.c", true },
  { "*.min.js", "dist/app.min.js", true },
  { "*.o", "a/b.o", true },
  { "*.[oa]", "lib.a", true },
  { "*.[!oa]", "lib.a", false },
  { "*.[!oa]", "lib.c", true },
  { "?.txt", "ab.txt", false },
  { "unclosed[", "unclosed[", true },
  { "build/**", "src/build/out.js", true },
}) do
  local pattern, path, expected = case[1], case[2], case[3]
  assert(
    watcher._is_ignored(path, { pattern }) == expected,
    string.format("glob %q against %q should be %s", pattern, path, tostring(expected))
  )
end

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
vim.fn.mkdir(root .. "/dist/nested", "p")
root = vim.uv.fs_realpath(root)
local function git(...)
  local result = vim.system(vim.list_extend({ "git", "-C", root }, { ... })):wait()
  assert(result.code == 0, result.stderr)
end
git("init", "-q")
vim.fn.writefile({ "dist/", "build/", "*.log" }, root .. "/.gitignore")
vim.fn.writefile({ "one" }, root .. "/src/tracked.lua")
vim.fn.writefile({ "kept" }, root .. "/forced.log")
git("add", ".gitignore", "src/tracked.lua")
git("add", "-f", "forced.log")
git("-c", "user.name=CI", "-c", "user.email=ci@example.test", "commit", "-qm", "fixture")

local ok, err = xpcall(function()
  -- Ignored files and directories come from Git; tracked files never match.
  local ignored = diff.ignored(root, { "dist/a.js", "src/tracked.lua", "forced.log", "new.log" })
  assert(ignored["dist/a.js"] and ignored["new.log"], "ignored paths are reported")
  assert(not ignored["src/tracked.lua"] and not ignored["forced.log"], "tracked files stay visible")
  assert(diff.ignored_directories(root, "").dist, "ignored directories are listed")
  assert(not diff.ignored_directories(root, "").src, "ordinary directories are not listed")

  -- Async review returns immediately and matches the synchronous comparison.
  vim.fn.writefile({ "one", "two" }, root .. "/src/tracked.lua")
  local done, async_result
  diff.async(diff.review, function(result)
    done, async_result = true, result
  end, root, "src/tracked.lua")
  assert(not done, "async review does not wait for Git")
  assert(vim.wait(5000, function()
    return done
  end, 10))
  assert(vim.deep_equal(async_result, diff.review(root, "src/tracked.lua")), "same comparison")
  local failure
  diff.async(function()
    error("boom")
  end, function(result, message)
    failure = { result = result, message = message }
  end)
  assert(vim.wait(1000, function()
    return failure ~= nil
  end, 10))
  assert(failure.result == nil and failure.message:find("boom"), "errors reach the callback")

  -- Per-directory platforms leave ignored trees unwatched, including new ones.
  local native_jit = jit
  _G.jit = setmetatable({ os = "Linux" }, { __index = native_jit })
  package.loaded["agent-lens.watcher"] = nil
  local per_dir = require("agent-lens.watcher")
  local watched = xpcall(function()
    per_dir.start(root, function() end, {
      ignored_directories = function(rel)
        return diff.ignored_directories(root, rel)
      end,
    })
    local handles = per_dir._instance.watchers
    assert(handles[root] and handles[root .. "/src"], "ordinary directories are watched")
    assert(not handles[root .. "/dist"] and not handles[root .. "/dist/nested"], "ignored tree")
    vim.fn.mkdir(root .. "/build/deep", "p")
    vim.fn.mkdir(root .. "/lib/inner", "p")
    assert(
      vim.wait(3000, function()
        return handles[root .. "/lib/inner"] ~= nil
      end, 20),
      "new ordinary directories are watched"
    )
    assert(not handles[root .. "/build"], "new ignored directories are not watched")
  end, debug.traceback)
  per_dir.stop()
  _G.jit = native_jit
  package.loaded["agent-lens.watcher"] = nil
  assert(watched)

  -- End to end: ignored and glob-ignored files never reach the timeline.
  local lens = require("agent-lens")
  local timeline = require("agent-lens.timeline")
  lens.setup({ enabled = false, inline = { enabled = false } })
  lens.start(root)
  vim.wait(200)
  for i = 1, 20 do
    vim.fn.writefile({ "built " .. i }, root .. "/dist/chunk" .. i .. ".js")
  end
  vim.fn.writefile({ "lock" }, root .. "/lazy-lock.json")
  vim.fn.writefile({ "debug" }, root .. "/debug.log")
  vim.fn.writefile({ "one", "two", "three" }, root .. "/src/tracked.lua")
  vim.fn.writefile({ "new" }, root .. "/src/untracked.lua")
  assert(
    vim.wait(5000, function()
      return #timeline.entries >= 2
    end, 20),
    "visible changes are recorded"
  )
  vim.wait(400)
  local recorded = {}
  for _, entry in ipairs(timeline.entries) do
    recorded[entry.rel_path] = true
  end
  assert(recorded["src/tracked.lua"] and recorded["src/untracked.lua"], "visible changes")
  for path in pairs(recorded) do
    assert(path:match("^src/"), "unexpected timeline entry: " .. path)
  end
  lens.stop()
end, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
print("ignore behavior OK")
vim.cmd("qa!")
