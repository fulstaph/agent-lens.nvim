-- Real sockets with scheduled decoding held until data and EOF have arrived.
vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false
local config = require("agent-lens.config")
local follow = require("agent-lens.follow")
local feed = require("agent-lens.read_events")
local live = require("agent-lens.live")
local status = require("agent-lens.status")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
assert(vim.system({ "git", "init", "-q", root }):wait().code == 0)
config.setup({
  enabled = false,
  reads = { interval_ms = 60000 },
  follow = { enabled = true, animation = false },
})
follow.setup(config.options.follow)
feed.start(root)
live.start(root)
local schedule = vim.schedule
local queue = {}
local client
local function drain()
  while #queue > 0 do
    table.remove(queue, 1)()
  end
end
local function preview(id, sequence, lines)
  return {
    v = 1,
    kind = "preview",
    tool = "write",
    toolCallId = id,
    path = "final.lua",
    sequence = sequence,
    line = #lines,
    agent = "pi",
    lines = lines,
  }
end
local function send_and_close(records)
  queue = {}
  vim.schedule = function(callback)
    queue[#queue + 1] = callback
  end
  client = assert(vim.uv.new_pipe(false))
  client:connect(live.directory(root) .. "/" .. vim.uv.os_getpid() .. ".sock", function(err)
    assert(not err, err)
    client:write(table.concat(records, "\n") .. "\n", function(write_err)
      assert(not write_err, write_err)
      client:shutdown(function()
        client:close()
      end)
    end)
  end)
  assert(
    vim.wait(2000, function()
      return #queue >= #records + 1
    end, 10),
    "socket data and EOF must arrive before decoding"
  )
end
local ok, err = xpcall(function()
  follow.record_preview(root, preview("older", 1, { "FROZEN" }))
  follow.pause("manual")
  vim.wait(30)
  send_and_close({
    vim.json.encode(preview("final", 1, { "FIRST" })),
    vim.json.encode(preview("final", 2, { "FINAL", "CONTENTS" })),
  })
  vim.fn.writefile({ "FINAL", "CONTENTS" }, root .. "/final.lua")
  vim.fn.mkdir(root .. "/.git/agent-lens", "p")
  vim.fn.writefile({
    vim.json.encode({
      v = 1,
      kind = "location",
      phase = "success",
      tool = "write",
      toolCallId = "final",
      path = "final.lua",
      line = 1,
      agent = "pi",
    }),
  }, root .. "/.git/agent-lens/reads.jsonl")
  drain()
  local facts = status.get()
  assert(
    facts.activity.call_id == "final" and facts.activity.phase == "settled",
    "EOF drains the final preview before correlated completion"
  )
  assert(facts.activity.line == 2, "last queued snapshot determines the final line")
  assert(
    facts.preview.state == "listening" and facts.preview.peers == 0 and facts.preview.last_valid_at,
    "drained receiver returns to listening"
  )
  assert(
    follow.state().control == "paused" and vim.api.nvim_get_current_line() == "FROZEN",
    "success preserves the paused view"
  )
  assert(follow.resume())
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "FINAL", "CONTENTS" }))
  vim.schedule = schedule
  vim.wait(20)
  send_and_close({ vim.json.encode(preview("cancelled", 1, { "UNFINISHED" })) })
  drain()
  assert(
    status.get().activity.phase == "idle" and not vim.b.agent_lens_preview,
    "unfinished EOF discards the decoded draft"
  )
  print("live queued EOF behavior OK")
end, debug.traceback)
vim.schedule = schedule
if client and not client:is_closing() then
  client:close()
end
live.stop()
feed.stop()
follow.clear()
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
vim.cmd("qa!")
