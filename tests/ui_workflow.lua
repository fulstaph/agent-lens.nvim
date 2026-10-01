vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false
local lens = require("agent-lens")
local follow = require("agent-lens.follow")
local panel = require("agent-lens.panel")
local timeline = require("agent-lens.timeline")
local review = require("agent-lens.diff_view")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
local function git(...)
  local args = { "git", "-C", root }
  vim.list_extend(args, { ... })
  assert(vim.system(args):wait().code == 0)
end
local ok, err = xpcall(function()
  git("init")
  git("config", "user.name", "Test")
  git("config", "user.email", "test@test")
  vim.fn.writefile({ "one", "two", "three" }, root .. "/a.lua")
  git("add", ".")
  git("commit", "-m", "init")
  lens.setup({ enabled = false, follow = { enabled = true, animation = false } })
  lens.start(root)
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/a.lua"))
  local origin = vim.api.nvim_get_current_win()
  local tab = vim.api.nvim_get_current_tabpage()
  local function draft(seq, text)
    follow.record_preview(root, {
      toolCallId = "call",
      tool = "edit",
      path = "a.lua",
      line = 2,
      sequence = seq,
      agent = "pi",
      lines = { "one", text, "three" },
    })
  end
  draft(1, "first")
  vim.api.nvim_feedkeys("k", "xt", false)
  assert(follow.state().control == "paused")
  local frozen = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  draft(2, "latest")
  assert(vim.deep_equal(frozen, vim.api.nvim_buf_get_lines(0, 0, -1, false)))
  vim.fn.writefile({ "one", "saved latest", "three" }, root .. "/a.lua")
  follow.record_location(
    root,
    { call_id = "call", phase = "success", tool = "edit", path = "a.lua", line = 2, agent = "pi" }
  )
  timeline.add({ rel_path = "a.lua", status = "modified", stats = { added = 1, removed = 1 } })
  lens.toggle()
  local selected = panel.selected().id
  vim.api.nvim_feedkeys("p", "xt", false)
  assert(review.is_open() and not timeline.unread_ids()[selected])
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
  assert(vim.api.nvim_get_current_tabpage() ~= tab and #vim.api.nvim_tabpage_list_wins(tab) == 2)
  review.close()
  assert(follow.state().control == "paused")
  panel.close()
  vim.api.nvim_set_current_win(origin)
  assert(lens.resume_follow())
  assert(vim.api.nvim_get_current_line() == "saved latest" and not vim.b.agent_lens_preview)
  local cmds = vim.api.nvim_get_commands({})
  for _, name in ipairs({
    "AgentLens",
    "AgentLensClear",
    "AgentLensClose",
    "AgentLensDiff",
    "AgentLensFollow",
    "AgentLensInlineToggle",
    "AgentLensStart",
    "AgentLensStop",
    "AgentLensPause",
    "AgentLensResume",
    "AgentLensFollowMode",
    "AgentLensStatus",
    "AgentLensFilter",
    "AgentLensPreview",
  }) do
    assert(cmds[name], name)
  end
  lens.stop()
  assert(lens.status().follow.control == "off" and lens.status().preview.state == "disabled")
  lens.setup({ enabled = false, reads = { enabled = true }, follow = { enabled = true } })
  lens.start(root)
  assert(not lens.toggle_follow())
  assert(require("agent-lens.read_events").is_running(), "read polling stays enabled")
  assert(lens.status().preview.state == "disabled")
  assert(lens.resume_follow())
  assert(lens.status().preview.state == "listening", "resume from off restarts preview receiver")
  follow.pause("manual")
  local live = require("agent-lens.live")
  local start = live.start
  local restarts = 0
  live.start = function(...)
    restarts = restarts + 1
    return start(...)
  end
  local resumed = lens.resume_follow()
  live.start = start
  assert(resumed and restarts == 0, "ordinary paused resume retains active preview receiver")
  lens.start(root)
  lens.setup({ enabled = false })
  assert(
    not require("agent-lens.read_events").is_running()
      and not require("agent-lens.watcher").is_running()
  )
  lens.setup({ enabled = true, watch_dir = root })
  lens.setup({ enabled = false })
  vim.wait(550)
  assert(
    not require("agent-lens.watcher").is_running(),
    "stale deferred setup cannot restart sources"
  )
  lens.start(root)
  timeline.add({ rel_path = "a.lua", status = "modified", stats = { added = 1, removed = 1 } })
  local other = vim.fn.tempname()
  vim.fn.mkdir(other, "p")
  vim.fn.system({ "git", "init", other })
  lens.start(other)
  assert(
    #timeline.entries == 0,
    "root changes cannot review old events against a different repository"
  )
  lens.stop()
  vim.fn.delete(other, "rf")
  print("ui workflow behavior OK")
end, debug.traceback)
lens.stop()
review.close()
panel.close()
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
vim.cmd("qa!")
