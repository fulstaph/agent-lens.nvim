-- Repository-relative bridge records must stay inside a watched subdirectory.
vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false
local lens = require("agent-lens")
local feed = require("agent-lens.read_events")
local follow = require("agent-lens.follow")
local live = require("agent-lens.live")
local timeline = require("agent-lens.timeline")
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src/src", "p")
root = vim.uv.fs_realpath(root)
assert(vim.system({ "git", "init", "-q", root }):wait().code == 0)
vim.fn.mkdir(root .. "/.git/agent-lens", "p")
vim.fn.writefile({ "right target", "second line" }, root .. "/src/sample.lua")
vim.fn.writefile({ "wrong duplicate" }, root .. "/src/src/sample.lua")
vim.fn.writefile({ "outside watch" }, root .. "/outside.lua")
local function emit(event)
  local file = assert(io.open(root .. "/.git/agent-lens/reads.jsonl", "ab"))
  assert(file:write(vim.json.encode(event) .. "\n"))
  file:close()
  feed.poll()
end
local client
local function send(event)
  local sent = false
  client:write(vim.json.encode(event) .. "\n", function(err)
    assert(not err, err)
    sent = true
  end)
  assert(vim.wait(2000, function()
    return sent
  end, 10))
end
local ok, err = xpcall(function()
  lens.setup({
    enabled = false,
    reads = { enabled = true },
    follow = { enabled = true, animation = false },
  })
  assert(lens.start(root .. "/src"))
  assert(
    live.directory(root) == live.directory(root .. "/src"),
    "socket discovery uses the repository root"
  )
  emit({ v = 1, kind = "read", path = "src/sample.lua", agent = "pi" })
  assert(#timeline.entries == 1 and timeline.entries[1].rel_path == "sample.lua")
  emit({ v = 1, kind = "read", path = "outside.lua", agent = "pi" })
  assert(#timeline.entries == 1, "out-of-scope reads are rejected")
  emit({
    v = 1,
    kind = "location",
    phase = "start",
    tool = "read",
    toolCallId = "read",
    path = "src/sample.lua",
    line = 2,
  })
  assert(
    vim.api.nvim_buf_get_name(0) == root .. "/src/sample.lua",
    "follow opens the rebased target"
  )
  assert(vim.api.nvim_win_get_cursor(0)[1] == 2)
  emit({
    v = 1,
    kind = "location",
    phase = "success",
    tool = "read",
    toolCallId = "read",
    path = "src/sample.lua",
  })

  client = assert(vim.uv.new_pipe(false))
  local connected = false
  client:connect(live.directory(root) .. "/" .. vim.uv.os_getpid() .. ".sock", function(connect_err)
    assert(not connect_err, connect_err)
    connected = true
  end)
  assert(vim.wait(2000, function()
    return connected
  end, 10))
  send({
    v = 1,
    kind = "preview",
    tool = "write",
    toolCallId = "draft",
    path = "src/new.lua",
    line = 1,
    sequence = 1,
    agent = "pi",
    lines = { "transient draft" },
  })
  assert(
    vim.wait(2000, function()
      return vim.b.agent_lens_preview == true
    end, 10),
    "repository socket delivers a subdirectory preview"
  )
  assert(
    lens.status().activity.path == "new.lua"
      and vim.api.nvim_get_current_line() == "transient draft"
  )
  send({
    v = 1,
    kind = "preview",
    tool = "write",
    toolCallId = "outside",
    path = "outside.lua",
    line = 1,
    sequence = 1,
    agent = "pi",
    lines = { "out of scope" },
  })
  vim.wait(50)
  assert(lens.status().activity.call_id == "draft", "out-of-scope previews are rejected")
  emit({ v = 1, kind = "location", phase = "error", tool = "write", toolCallId = "draft" })
  assert(not vim.b.agent_lens_preview and follow.state().control == "following")
end, debug.traceback)
if client and not client:is_closing() then
  client:close()
end
lens.stop()
vim.fn.delete(root, "rf")
assert(ok, err)
print("subdirectory bridge OK")
vim.cmd("qa!")
