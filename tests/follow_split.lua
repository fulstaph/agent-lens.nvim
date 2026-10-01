vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false
local config = require("agent-lens.config")
local follow = require("agent-lens.follow")
local view = require("agent-lens.follow_view")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
vim.fn.writefile({ "one", "two" }, root .. "/file.lua")
local function preview(seq)
  follow.record_preview(root, {
    toolCallId = "call",
    path = "file.lua",
    tool = "edit",
    sequence = seq,
    line = 2,
    agent = "pi",
    lines = { "one", "draft " .. seq },
  })
end
local ok, err = xpcall(function()
  config.setup({ enabled = false, follow = { enabled = true, animation = false } })
  follow.setup(config.options.follow)
  assert(follow.set_window("split"))
  local win = vim.api.nvim_get_current_win()
  local source = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "unsaved" })
  preview(1)
  local agent = view.current().win
  assert(agent ~= win and vim.api.nvim_get_current_win() == win, "split_keeps_focus")
  local insert_checked = false
  vim.api.nvim_create_autocmd("InsertEnter", {
    once = true,
    callback = function()
      preview(2)
      assert(follow.state().control == "following", "split continues while typing elsewhere")
      insert_checked = true
    end,
  })
  vim.api.nvim_feedkeys(
    "iX" .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
    "xt",
    false
  )
  assert(insert_checked, "actual Insert state checked")
  assert(follow.state().control == "following", "unrelated_edit_does_not_pause")
  vim.api.nvim_set_current_win(agent)
  vim.api.nvim_feedkeys("k", "xt", false)
  assert(follow.state().control == "paused", "input_inside_split_pauses")
  assert(follow.resume())
  vim.api.nvim_set_current_win(win)
  local tab = vim.api.nvim_get_current_tabpage()
  local before = vim.api.nvim_buf_get_lines(view.current().buf, 0, -1, false)
  vim.cmd("tabnew")
  preview(3)
  assert(follow.state().control == "following")
  assert(
    vim.deep_equal(
      before,
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(agent), 0, -1, false)
    ),
    "inactive tab frozen"
  )
  vim.api.nvim_set_current_tabpage(tab)
  assert(
    vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(agent), 0, -1, false)[2] == "draft 3",
    "inactive_tab_catches_up"
  )
  vim.api.nvim_win_close(agent, true)
  preview(4)
  assert(
    follow.state().control == "paused" and #vim.api.nvim_tabpage_list_wins(tab) == 1,
    "closed split not recreated"
  )
  assert(follow.resume())
  agent = view.current().win
  local user = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(user, 0, -1, false, { "user buffer" })
  vim.api.nvim_win_set_buf(agent, user)
  follow.stop()
  assert(
    vim.api.nvim_win_is_valid(agent) and vim.api.nvim_win_get_buf(agent) == user,
    "repurposed split survives"
  )
  assert(not follow.set_window("wrong"))
  vim.o.columns = 25
  assert(follow.set_window("split"))
  follow.resume()
  preview(4)
  assert(vim.api.nvim_win_get_width(view.current().win) >= 1)
  print("follow split behavior OK")
end, debug.traceback)
follow.stop()
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
vim.cmd("qa!")
