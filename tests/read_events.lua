vim.opt.rtp:append(vim.fn.getcwd())

local lens = require("agent-lens")
local timeline = require("agent-lens.timeline")
local feed = require("agent-lens.read_events")
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.git/agent-lens", "p")
assert(vim.fn.system({ "git", "init", root }) ~= "" and vim.v.shell_error == 0, "git init")
vim.fn.writefile({ "hello" }, root .. "/sample.lua")
vim.fn.system({ "git", "-C", root, "add", "sample.lua" })
assert(vim.v.shell_error == 0, "git add")
vim.fn.system({
  "git",
  "-C",
  root,
  "-c",
  "user.name=CI",
  "-c",
  "user.email=ci@example.test",
  "commit",
  "-qm",
  "fixture",
})
assert(vim.v.shell_error == 0, "git commit")
local events = root .. "/.git/agent-lens/reads.jsonl"

local function append(text)
  local file = assert(io.open(events, "ab"))
  assert(file:write(text))
  assert(file:close())
end

local function count()
  return #timeline.entries
end
lens.setup({ enabled = false })
lens.start(root)
assert(not feed.is_running(), "read tracking must be off by default")
lens.stop()

lens.setup({ enabled = false, reads = { enabled = true, interval_ms = 100 } })
lens.start(root)
assert(feed.is_running(), "enabled feed should start")
append('{"v":1,"kind":"read","path":"sample.lua","agent":"pi"}\n')
assert(
  vim.wait(2000, function()
    return count() == 1
  end, 20),
  "timer should deliver successful read"
)
assert(timeline.entries[1].kind == "read", "successful read appears")
assert(timeline.entries[1].rel_path == "sample.lua", "read path preserved")
assert(timeline.entries[1].agent == "pi", "agent label preserved")

append('{"v":1,"kind":"read","path":"../outside.lua"}\n')
append('{"v":1,"kind":"read","path":"/tmp/outside.lua"}\n')
append('{"v":1,"kind":"read","path":".git/config"}\n')
append('{"v":1,"kind":"edit","path":"sample.lua"}\n')
append("not-json\n")
feed.poll()
assert(count() == 1, "invalid paths and event types must be ignored")

append('{"v":1,"kind":"read","path":"sample.lua"}')
feed.poll()
assert(count() == 1, "partial event must wait for newline")
append("\n")
feed.poll()
assert(count() == 2, "completed event is delivered exactly once")
feed.poll()
assert(count() == 2, "poll does not replay events")
vim.wait(400, function()
  return false
end, 50)
assert(
  count() == 2,
  "read log must not appear as a filesystem edit: " .. vim.inspect(timeline.entries)
)

local panel = require("agent-lens.panel")
panel.open()
assert(
  vim.api.nvim_buf_get_lines(panel._buf, 3, 4, false)[1]:find("READ", 1, true),
  "timeline labels reads"
)
lens.show_diff()
assert(
  vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    == vim.uv.fs_realpath(root .. "/sample.lua"),
  "read opens file"
)

lens.stop()
assert(not feed.is_running(), "stop releases feed")
vim.fn.delete(root, "rf")
print("read events OK")
vim.cmd("qa!")
