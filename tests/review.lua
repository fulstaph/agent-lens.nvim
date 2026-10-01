vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false
local config = require("agent-lens.config")
config.setup({ enabled = false, follow = { enabled = true, animation = false } })
local review = require("agent-lens.diff_view")
local follow = require("agent-lens.follow")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
local function git(...)
  local args = { "git", "-C", root }
  vim.list_extend(args, { ... })
  local r = vim.system(args):wait()
  assert(r.code == 0, r.stderr)
end
local ok, err = xpcall(function()
  git("init")
  git("config", "user.name", "Test")
  git("config", "user.email", "test@test")
  local lines = {}
  for i = 1, 30 do
    lines[i] = "line " .. i
  end
  vim.fn.writefile(lines, root .. "/a.lua")
  vim.fn.writefile({ "old" }, root .. "/b.lua")
  git("add", ".")
  git("commit", "-m", "init")
  lines[2] = "NEW FIRST"
  lines[25] = "NEW LAST"
  vim.fn.writefile(lines, root .. "/a.lua")
  vim.fn.writefile({ "new" }, root .. "/b.lua")
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/a.lua"))
  local origin = vim.api.nvim_get_current_win()
  local tab = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_win_set_cursor(origin, { 12, 1 })
  vim.cmd("vsplit")
  local spare = vim.api.nvim_get_current_win()
  vim.cmd("enew")
  local unsaved = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(unsaved, 0, -1, false, { "unsaved" })
  vim.api.nvim_set_current_win(origin)
  local before = vim.fn.winsaveview()
  local entry = {
    rel_path = "a.lua",
    status = "modified",
    diff_cached = {
      hunks = { { lines = { "STALE" } } },
    },
  }
  assert(review.preview(entry, { root = root }), "hunk_preview_and_refresh")
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("NEW FIRST", 1, true))
  assert(review.navigate_hunk(1))
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("NEW LAST", 1, true))
  lines[25] = "line 25"
  vim.fn.writefile(lines, root .. "/a.lua")
  assert(review.refresh())
  assert(
    table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("NEW FIRST", 1, true),
    "refresh clamps hunk"
  )
  assert(review.open(entry, { root = root }))
  assert(vim.api.nvim_get_current_tabpage() ~= tab)
  assert(#vim.api.nvim_tabpage_list_wins(tab) == 2, "review_preserves_original_layout")
  assert(review.navigate_file(1))
  assert(vim.wo.winbar:find("b.lua", 1, true))
  review.close()
  assert(vim.api.nvim_get_current_win() == origin and vim.deep_equal(before, vim.fn.winsaveview()))
  assert(
    vim.api.nvim_buf_get_lines(unsaved, 0, -1, false)[1] == "unsaved"
      and vim.api.nvim_win_is_valid(spare)
  )
  for _, path in ipairs({ "untracked.lua", "staged.lua" }) do
    vim.fn.writefile({ "new text" }, root .. "/" .. path)
    if path == "staged.lua" then
      git("add", "--", path)
    end
    assert(review.open({ rel_path = path }, { root = root }))
    local sides = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local side = vim.wo[win].winbar:match("^(%w+)")
      sides[side] = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    end
    assert(vim.deep_equal(sides.HEAD, { "" }), "added file HEAD pane must be empty: " .. path)
    assert(vim.deep_equal(sides.disk, { "new text" }), "added file disk pane")
    review.close()
  end
  vim.fn.delete(root .. "/b.lua")
  assert(review.open({ rel_path = "b.lua" }, { root = root }))
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "" }),
    "deleted disk pane empty"
  )
  review.close()
  vim.fn.writefile({ "new" }, root .. "/b.lua")
  assert(review.open(entry, { root = root }))
  local reused = vim.api.nvim_get_current_win()
  local user = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(user, 0, -1, false, { "user review tab" })
  vim.api.nvim_win_set_buf(reused, user)
  review.close()
  assert(
    vim.api.nvim_win_is_valid(reused) and vim.api.nvim_win_get_buf(reused) == user,
    "repurposed review survives"
  )
  vim.api.nvim_set_current_win(origin)
  local lens = require("agent-lens")
  lens.setup({ enabled = false, follow = { enabled = true, animation = false } })
  lens._root = root
  vim.cmd("AgentLensPreview")
  assert(review.is_open(), "public preview command uses current watched file")
  assert(follow.state().control == "paused", "current_vs_split_follow_review current pauses")
  review.close()
  assert(follow.state().control == "paused", "close does not resume")
  assert(follow.set_window("split"))
  follow.resume()
  follow.record_location(
    root,
    { call_id = "reading", phase = "start", tool = "read", path = "a.lua", line = 2, agent = "pi" }
  )
  assert(lens.show_diff(entry))
  assert(follow.state().control == "following", "split remains following in review")
  review.close()
  assert(review.preview(entry, { root = root }))
  vim.api.nvim_win_close(spare, true)
  vim.api.nvim_win_close(origin, true)
  review.close()
  assert(vim.api.nvim_win_is_valid(reused), "missing origin chooses surviving user window")
  print("review behavior OK")
end, debug.traceback)
review.close()
follow.stop()
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
vim.cmd("qa!")
