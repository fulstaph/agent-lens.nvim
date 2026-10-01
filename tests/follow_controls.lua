vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false
local config = require("agent-lens.config")
local follow = require("agent-lens.follow")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
vim.fn.writefile({ "one", "two", "three" }, root .. "/file.lua")
local function setup(animation)
  follow.clear()
  vim.cmd("stopinsert")
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  config.setup({ enabled = false, follow = { enabled = true, animation = animation or false } })
  follow.setup(config.options.follow)
end
local function event(seq, text)
  return {
    toolCallId = "call",
    tool = "edit",
    path = "file.lua",
    line = 2,
    sequence = seq,
    agent = "pi",
    lines = { "one", text, "three" },
  }
end
local ok, err = xpcall(function()
  setup()
  follow.record_preview(root, event(1, "first"))
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  assert(follow.pause("navigation"))
  assert(follow.is_enabled() and follow.state().control == "paused")
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local view = vim.fn.winsaveview()
  for i = 2, 100 do
    follow.record_preview(root, event(i, "newest " .. i))
  end
  assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
  assert(vim.deep_equal(view, vim.fn.winsaveview()))
  assert(follow.resume())
  assert(vim.api.nvim_get_current_line() == "newest 100")
  setup(true)
  follow.record_preview(root, event(1, string.rep("long ", 100)))
  vim.api.nvim_feedkeys("k", "xt", false)
  assert(follow.state().control == "paused", "actual navigation pauses")
  buf = vim.api.nvim_get_current_buf()
  before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  view = vim.fn.winsaveview()
  follow.record_preview(root, event(2, "queued latest"))
  vim.wait(220)
  assert(
    vim.deep_equal(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      and vim.deep_equal(view, vim.fn.winsaveview())
  )
  setup()
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/file.lua"))
  local source = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(
    source,
    0,
    -1,
    false,
    { "unsaved one", "unsaved two", "unsaved three" }
  )
  follow.record_preview(root, event(1, "draft"))
  win = require("agent-lens.follow_view").current().win
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(
    "iX" .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
    "xt",
    false
  )
  assert(
    follow.state().control == "paused" and vim.api.nvim_get_current_buf() == source,
    "Insert hands back source"
  )
  assert(
    vim.api.nvim_buf_get_lines(source, 0, -1, false)[2]:find("X", 1, true),
    "input enters source"
  )
  assert(vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == "unsaved one")
  for _, case in ipairs({
    { keys = "oX", want = { "unsaved one", "unsaved two", "X", "unsaved three" } },
    { keys = "cwX", want = { "unsaved one", "X two", "unsaved three" } },
    { keys = "sX", want = { "unsaved one", "Xnsaved two", "unsaved three" } },
  }) do
    setup()
    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/file.lua"))
    source = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(
      source,
      0,
      -1,
      false,
      { "unsaved one", "unsaved two", "unsaved three" }
    )
    follow.record_preview(root, event(1, "draft"))
    vim.api.nvim_set_current_win(require("agent-lens.follow_view").current().win)
    follow.pause("manual")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.v.errmsg = ""
    vim.api.nvim_feedkeys(
      case.keys .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
      "xt",
      false
    )
    assert(
      vim.api.nvim_get_current_buf() == source,
      "paused draft hands back source before " .. case.keys
    )
    assert(
      vim.deep_equal(case.want, vim.api.nvim_buf_get_lines(source, 0, -1, false)),
      "paused editing preserves source text: " .. case.keys
    )
    assert(vim.v.errmsg == "", "paused editing does not raise E21")
  end
  setup()
  follow.record_preview(root, event(1, "draft"))
  follow.pause("test")
  follow.record_location(root, {
    call_id = "call",
    phase = "success",
    tool = "edit",
    path = "file.lua",
    line = 2,
    agent = "pi",
  })
  follow.preview_disconnected(root, "call")
  assert(follow.resume())
  assert(not vim.b.agent_lens_preview)
  assert(not follow.record_preview(root, event(2, "late")))
  setup()
  follow.record_preview(root, event(1, "draft"))
  follow.pause("test")
  follow.record_location(root, { call_id = "call", phase = "error", tool = "edit", agent = "pi" })
  assert(not vim.b.agent_lens_preview)
  assert(not follow.record_preview(root, event(2, "late")))
  follow.clear()
  assert(follow.state().control == "following")
  follow.stop()
  assert(follow.state().control == "off")
  setup()
  follow.record_preview(root, event(1, "old"))
  follow.clear()
  local other = vim.fn.tempname()
  vim.fn.mkdir(other, "p")
  other = vim.uv.fs_realpath(other)
  vim.fn.writefile({ "other", "source" }, other .. "/file.lua")
  follow.record_preview(other, event(1, "new root"))
  follow.pause("test")
  local current = vim.api.nvim_get_current_buf()
  follow.preview_disconnected(root, "call")
  assert(
    vim.api.nvim_get_current_buf() == current and follow.state().control == "paused",
    "stale_root_snapshot"
  )
  vim.fn.delete(other, "rf")
  setup()
  local modal_checked = false
  vim.api.nvim_create_autocmd("CmdwinEnter", {
    once = true,
    callback = function()
      follow.record_preview(root, event(1, "unsafe"))
      assert(follow.state().control == "paused", "unsafe_modal_state")
      modal_checked = true
    end,
  })
  vim.api.nvim_feedkeys(
    "q:" .. vim.api.nvim_replace_termcodes("<Esc>:q<CR>", true, false, true),
    "xt",
    false
  )
  assert(modal_checked, "actual command-line window exercised")
  vim.wait(40, function()
    return vim.fn.getcmdwintype() == ""
  end)
  setup()
  local notify = vim.notify
  local notices = {}
  vim.notify = function(message)
    notices[#notices + 1] = message
  end
  follow.record_preview(root, event(1, "notice"))
  follow.pause("manual")
  follow.pause("manual")
  for i = 2, 10 do
    follow.record_preview(root, event(i, "latest"))
  end
  vim.wait(20)
  assert(#notices == 1, "pause is visible once with panel closed, without frame spam")
  follow.resume()
  vim.wait(20)
  assert(#notices == 2, "resume is visible once")
  vim.notify = notify
  print("follow controls behavior OK")
end, debug.traceback)
follow.clear()
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
vim.cmd("qa!")
