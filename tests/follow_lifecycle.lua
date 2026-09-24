vim.opt.rtp:append(vim.fn.getcwd())

local config = require("agent-lens.config")
local follow = require("agent-lens.follow")
local namespace = vim.api.nvim_get_namespaces().agent_lens_follow
local failures = {}
local notifications = {}
local notify = vim.notify
vim.notify = function(message)
  notifications[#notifications + 1] = message
end
vim.o.swapfile = false
vim.o.autoread = false

local function location(root, id, phase, path, line, tool)
  follow.record_location(root, {
    call_id = id,
    phase = phase,
    tool = tool or "edit",
    path = path,
    line = line or 1,
    agent = "pi",
    sequence = phase == "progress" and 1 or nil,
  })
end

local function content(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function mark_count()
  local count = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      count = count + #vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {})
    end
  end
  return count
end

local function test(name, run)
  if arg[1] and arg[1] ~= name then
    return
  end
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = assert(vim.uv.fs_realpath(root))
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("silent! %bwipeout!")
  vim.wo.winfixbuf = false
  vim.wo.cursorbind = false
  vim.wo.scrollbind = false
  config.setup({ enabled = false })
  follow.setup({ enabled = true })
  notifications = {}
  local ok, err = xpcall(function()
    run(root)
  end, debug.traceback)
  follow.clear()
  vim.cmd("silent! %bwipeout!")
  vim.fn.delete(root, "rf")
  if ok then
    print("PASS " .. name)
  else
    failures[#failures + 1] = name .. ": " .. err
    print("FAIL " .. failures[#failures])
  end
end

test("current_window", function(root)
  local lines = {}
  for line = 1, 200 do
    lines[line] = "source line " .. line
  end
  vim.fn.writefile(lines, root .. "/target.txt")
  local current = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local spare = vim.api.nvim_get_current_win()
  vim.cmd("enew")
  vim.api.nvim_set_current_win(current)
  location(root, "read", "start", "target.txt", 150, "read")
  assert(vim.api.nvim_get_current_win() == current, "follow keeps the selected window")
  assert(
    vim.api.nvim_buf_get_name(0) == vim.uv.fs_realpath(root .. "/target.txt"),
    "follow uses current editor window"
  )
  assert(
    vim.api.nvim_win_get_cursor(current)[1] == 150,
    "cursor follows so redraw cannot snap viewport away"
  )
  assert(
    vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(spare)) == "",
    "spare window is not taken over"
  )
  assert(#vim.api.nvim_tabpage_list_wins(0) == 2, "navigation does not create an extra split")
end)

test("created_edit", function(root)
  location(root, "create", "progress", "new.txt")
  local buf = vim.fn.bufnr(root .. "/new.txt")
  assert(vim.deep_equal(content(buf), { "" }), "draft starts before disk creation")
  local written = { "first disk line", "second disk line", "third disk line" }
  vim.fn.writefile(written, root .. "/new.txt")
  location(root, "create", "start", "new.txt")
  location(root, "create", "success", "new.txt", 3)
  assert(
    vim.deep_equal(content(buf), written),
    "created file replaces empty draft with real disk content"
  )
  assert(vim.api.nvim_win_get_cursor(0)[1] == 3, "success follows the real created line")
end)

test("changed_file", function(root)
  vim.fn.writefile({ "old disk text" }, root .. "/existing.txt")
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/existing.txt"))
  local buf = vim.api.nvim_get_current_buf()
  location(root, "read", "start", "existing.txt", 1, "read")
  local written = { "new disk text is longer", "second line" }
  vim.fn.writefile(written, root .. "/existing.txt")
  location(root, "read", "success", "existing.txt", 2, "read")
  assert(vim.deep_equal(content(buf), written), "successful read displays latest disk version")
  vim.fn.writefile({ "later external update" }, root .. "/existing.txt")
  follow.file_changed(root, "existing.txt")
  assert(
    vim.deep_equal(content(buf), { "later external update" }),
    "active read target also refreshes on disk events"
  )
end)

test("modified_buffer", function(root)
  vim.fn.writefile({ "original" }, root .. "/local.txt")
  vim.fn.writefile({ "agent target" }, root .. "/other.txt")
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/local.txt"))
  local user_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved user text", "keep me" })
  vim.api.nvim_win_set_cursor(user_win, { 2, 3 })
  location(root, "elsewhere", "start", "other.txt", 1, "read")
  assert(vim.api.nvim_get_current_win() == user_win, "protected current window keeps focus")
  assert(vim.api.nvim_win_get_buf(user_win) == buf, "modified user buffer is not replaced")
  assert(
    vim.deep_equal(vim.api.nvim_win_get_cursor(user_win), { 2, 3 }),
    "protected user cursor stays put"
  )
  vim.fn.writefile({ "different disk text" }, root .. "/local.txt")
  location(root, "same", "start", "local.txt", 1, "read")
  location(root, "same", "success", "local.txt", 1, "read")
  follow.file_changed(root, "local.txt")
  assert(
    vim.deep_equal(content(buf), { "unsaved user text", "keep me" }),
    "no reload discards unsaved edits"
  )
  assert(vim.bo[buf].modified, "unsaved state is retained")
end)

test("modified_draft", function(root)
  location(root, "draft", "progress", "new.txt")
  local buf = vim.fn.bufnr(root .. "/new.txt")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "user draft" })
  vim.fn.writefile({ "agent disk version" }, root .. "/new.txt")
  location(root, "draft", "start", "new.txt")
  location(root, "draft", "success", "new.txt")
  follow.file_changed(root, "new.txt")
  assert(
    vim.deep_equal(content(buf), { "user draft" }),
    "creation never overwrites a modified draft"
  )
  assert(vim.bo[buf].modified, "draft remains unsaved")
end)

test("modified_draft_checktime", function(root)
  location(root, "draft", "progress", "new.txt")
  local buf = vim.fn.bufnr(root .. "/new.txt")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved user draft" })
  vim.fn.writefile({ "agent-created file" }, root .. "/new.txt")
  follow.file_changed(root, "new.txt")
  vim.cmd("silent! checktime")
  assert(
    vim.deep_equal(content(buf), { "unsaved user draft" }),
    "checktime never reloads a modified draft"
  )
  assert(vim.bo[buf].modified, "created file leaves draft unsaved")
  assert(
    table.concat(notifications, "\n"):find("unsaved", 1, true),
    "conflicting disk creation is reported"
  )
end)

test("deleted_edit", function(root)
  vim.fn.writefile({ "previous disk content" }, root .. "/gone.txt")
  location(root, "edit", "start", "gone.txt")
  local buf = vim.fn.bufnr(root .. "/gone.txt")
  assert(mark_count() == 1, "initial edit target is shown")
  vim.fn.delete(root .. "/gone.txt")
  follow.file_changed(root, "gone.txt")
  assert(mark_count() == 0, "deleted target no longer has a live marker")
  assert(
    vim.deep_equal(content(buf), { "previous disk content" }),
    "deletion does not erase the buffer"
  )
end)

test("reload_preserves_other_views", function(root)
  local lines = {}
  for line = 1, 200 do
    lines[line] = "original " .. line
  end
  vim.fn.writefile(lines, root .. "/target.txt")
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/target.txt"))
  local buf = vim.api.nvim_get_current_buf()
  local float = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 30,
    height = 8,
  })
  vim.api.nvim_win_set_cursor(float, { 90, 0 })
  local float_view = vim.api.nvim_win_call(float, function()
    return vim.fn.winsaveview()
  end)
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/user.txt"))
  local user_win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved user text" })
  vim.api.nvim_win_set_cursor(user_win, { 1, 5 })
  location(root, "read", "start", "target.txt", 150, "read")
  local float_at_start = vim.api.nvim_win_call(float, function()
    return vim.fn.winsaveview()
  end)
  assert(vim.deep_equal(float_at_start, float_view), "first Follow load preserves an existing view")
  local changed = {}
  for line = 1, 200 do
    changed[line] = "changed " .. line
  end
  vim.fn.writefile(changed, root .. "/target.txt")
  follow.file_changed(root, "target.txt")
  local float_after = vim.api.nvim_win_call(float, function()
    return vim.fn.winsaveview()
  end)
  assert(
    vim.deep_equal(float_after, float_view),
    "reload leaves the unrelated floating view untouched"
  )
  assert(vim.api.nvim_get_current_win() == user_win, "reload preserves the user's active window")
  assert(vim.api.nvim_win_get_cursor(user_win)[2] == 5, "reload preserves the user's cursor")
  assert(vim.deep_equal(content(buf), changed), "followed target loads the new source")
end)

test("pinned_window", function(root)
  vim.fn.writefile({ "target text" }, root .. "/target.txt")
  vim.cmd("enew")
  local pinned = vim.api.nvim_get_current_win()
  local original = vim.api.nvim_get_current_buf()
  vim.wo[pinned].winfixbuf = true
  location(root, "read", "start", "target.txt", 1, "read")
  assert(vim.api.nvim_win_get_buf(pinned) == original, "pinned window remains on its buffer")
  assert(vim.api.nvim_get_current_win() == pinned, "pinned window keeps focus")
  assert(mark_count() == 1, "follow uses a safe fallback rather than dropping location")
  assert(#vim.api.nvim_tabpage_list_wins(0) == 2, "fallback opens one split")
end)

test("bound_window", function(root)
  local lines = {}
  for line = 1, 200 do
    lines[line] = "source " .. line
  end
  vim.fn.writefile(lines, root .. "/target.txt")
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/user.txt"))
  local user_win = vim.api.nvim_get_current_win()
  vim.wo[user_win].cursorbind = true
  vim.wo[user_win].scrollbind = true
  vim.api.nvim_win_set_cursor(user_win, { 1, 0 })
  location(root, "read", "start", "target.txt", 150, "read")
  assert(
    vim.api.nvim_win_get_buf(user_win) ~= vim.fn.bufnr(root .. "/target.txt"),
    "bound window is protected"
  )
  assert(vim.api.nvim_win_get_cursor(user_win)[1] == 1, "bound cursor is not moved")
  assert(#vim.api.nvim_tabpage_list_wins(0) == 2, "a safe split shows the target")
  local other = vim.api.nvim_tabpage_list_wins(0)[2]
  if other == user_win then
    other = vim.api.nvim_tabpage_list_wins(0)[1]
  end
  assert(
    not vim.wo[other].cursorbind and not vim.wo[other].scrollbind,
    "split does not inherit binding"
  )
  assert(vim.api.nvim_win_get_cursor(other)[1] == 150, "new window follows the agent")
end)

test("failed_load", function(root)
  local path = root .. "/reader.txt"
  vim.fn.writefile({ "recovered source", "second line" }, path)
  local fail = true
  local group = vim.api.nvim_create_augroup("AgentLensFailingReader", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = path,
    callback = function(event)
      if fail then
        error("fixture read failure")
      end
      vim.api.nvim_buf_set_lines(event.buf, 0, -1, false, vim.fn.readfile(path))
      vim.bo[event.buf].modified = false
    end,
  })
  local ok, err = pcall(function()
    location(root, "failed", "start", "reader.txt", 1, "read")
    assert(mark_count() == 0, "failed source load does not render")
    location(root, "failed", "success", "reader.txt", 1, "read")
    assert(mark_count() == 0, "loaded empty buffer is not mistaken for a successful read")
    assert(
      table.concat(notifications, "\n"):find("fixture read failure", 1, true),
      "load failure reports its cause"
    )
    local buf = vim.fn.bufnr(path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "user typed after load failed" })
    location(root, "manual", "start", "reader.txt", 1, "read")
    assert(mark_count() == 1, "modified buffer is available even after a failed disk read")
    assert(
      vim.deep_equal(content(buf), { "user typed after load failed" }),
      "unsaved text is not retried"
    )
    vim.bo[buf].modified = false
    fail = false
    location(root, "retry", "start", "reader.txt", 2, "read")
    buf = vim.fn.bufnr(path)
    assert(
      vim.deep_equal(content(buf), { "recovered source", "second line" }),
      "normal reader retries after load failure"
    )
    assert(mark_count() == 1, "recovered target renders once")
  end)
  vim.api.nvim_del_augroup_by_id(group)
  assert(ok, err)
end)

test("replaced_symlink", function(root)
  local outside = vim.fn.tempname()
  vim.fn.writefile({ "outside repository" }, outside)
  vim.fn.writefile({ "safe original" }, root .. "/target.txt")
  local ok, err = pcall(function()
    location(root, "read", "start", "target.txt", 1, "read")
    vim.fn.delete(root .. "/target.txt")
    assert(vim.uv.fs_symlink(outside, root .. "/target.txt"))
    follow.file_changed(root, "target.txt")
    assert(vim.fn.bufnr(outside) == -1, "deferred refresh must not open a substituted outside path")
    assert(mark_count() == 0, "unsafe replacement does not retain a successful Follow marker")
  end)
  vim.fn.delete(root .. "/target.txt")
  vim.fn.delete(outside)
  assert(ok, err)
end)

test("active_tab", function(root)
  vim.fn.writefile({ "first target" }, root .. "/first.txt")
  vim.fn.writefile({ "second target" }, root .. "/second.txt")
  location(root, "first", "start", "first.txt", 1, "read")
  local old_win = vim.api.nvim_get_current_win()
  vim.cmd("tabnew")
  local active_win = vim.api.nvim_get_current_win()
  location(root, "second", "start", "second.txt", 1, "read")
  assert(vim.api.nvim_get_current_win() == active_win, "follow does not switch tab or focus")
  assert(
    vim.api.nvim_buf_get_name(0) == vim.uv.fs_realpath(root .. "/second.txt"),
    "new target is visible in active tab"
  )
  assert(
    vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(old_win))
      == vim.uv.fs_realpath(root .. "/first.txt"),
    "hidden tab is not repurposed"
  )
end)

vim.notify = notify
assert(#failures == 0, table.concat(failures, "\n"))
print("follow lifecycle OK")
vim.cmd("qa!")
