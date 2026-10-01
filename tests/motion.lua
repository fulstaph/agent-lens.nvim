vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false
local config = require("agent-lens.config")
local motion = require("agent-lens.motion")
local follow = require("agent-lens.follow")
local failures = {}

local function test(name, run)
  motion.stop()
  follow.clear()
  vim.cmd("silent! only!")
  vim.cmd("silent! %bwipeout!")
  config.setup({ enabled = false, follow = { enabled = true, animation_ms = 160 } })
  follow.setup(config.options.follow)
  local ok, err = xpcall(run, debug.traceback)
  motion.stop()
  follow.clear()
  if ok then
    print("PASS " .. name)
  else
    failures[#failures + 1] = name .. ": " .. err
    print("FAIL " .. failures[#failures])
  end
end

local function draft(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  return buf
end

local function content(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

test("progressive_utf8_reveal", function()
  local buf = draft({ "header", "old", "tail" })
  local frames = {}
  local desired = { "header", "a growing π🌱 replacement", "second line", "tail" }
  motion.reveal(buf, desired, 3, function(row, col, done)
    local lines = content(buf)
    assert(lines[1] == "header" and lines[#lines] == "tail", "unchanged context stays still")
    local joined = table.concat(lines, "\n")
    assert(vim.fn.iconv(joined, "utf-8", "utf-8") == joined, "frames retain valid UTF-8")
    assert(col <= #lines[row], "caret uses a valid byte column")
    frames[#frames + 1] = { text = joined, done = done }
  end)
  assert(not vim.deep_equal(content(buf), desired), "first paint does not dump the whole snapshot")
  assert(
    vim.wait(500, function()
      return not motion.is_revealing(buf)
    end, 5),
    "reveal completes within its latency budget"
  )
  assert(vim.deep_equal(content(buf), desired), "final snapshot is exact")
  assert(#frames >= 3 and frames[#frames].done, "multiple real animation frames are produced")
  assert(not vim.bo[buf].modified and not vim.bo[buf].modifiable, "draft stays read-only")
end)

test("retarget_without_backlog", function()
  local buf = draft({ "" })
  local first = { string.rep("first ", 30) }
  local latest = { "latest replacement", "new row" }
  local frames = 0
  local callback = function()
    frames = frames + 1
  end
  motion.reveal(buf, first, 1, callback)
  vim.wait(40, function()
    return false
  end, 5)
  motion.reveal(buf, latest, 2, callback)
  assert(
    vim.wait(250, function()
      return not motion.is_revealing(buf)
    end, 5),
    "new snapshots do not extend the deadline indefinitely"
  )
  assert(vim.deep_equal(content(buf), latest), "newest snapshot wins")
  assert(frames >= 3, "retargeting retains intermediate frames")
end)

test("cancellation_and_reduced_motion", function()
  local buf = draft({ "" })
  local frames = 0
  motion.reveal(buf, { "cancel this staged text" }, 1, function()
    frames = frames + 1
  end)
  motion.stop(buf)
  local cancelled = content(buf)
  local count = frames
  vim.wait(200, function()
    return false
  end, 5)
  assert(
    frames == count and vim.deep_equal(content(buf), cancelled),
    "cancelled callbacks stay cancelled"
  )
  config.setup({ follow = { animation = false } })
  motion.reveal(buf, { "immediate text" }, 1, function() end)
  assert(vim.deep_equal(content(buf), { "immediate text" }), "reduced motion renders immediately")
  assert(not motion.is_revealing(buf), "reduced motion starts no reveal timer")
end)

test("viewport_easing_and_protected_window", function()
  local lines = {}
  for row = 1, 100 do
    lines[row] = "line " .. row
  end
  local buf = draft(lines)
  vim.api.nvim_win_set_buf(0, buf)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  motion.view(win, buf, 80, 3)
  assert(vim.api.nvim_win_get_cursor(win)[1] ~= 80, "offscreen targets ease into view")
  assert(
    vim.wait(300, function()
      return vim.api.nvim_win_get_cursor(win)[1] == 80
    end, 5),
    "viewport reaches the requested line"
  )
  assert(vim.api.nvim_win_get_cursor(win)[2] == 3, "cursor follows the drafting column")
  motion.view(win, buf, 20, 0)
  vim.wo[win].cursorbind = true
  local cursor = vim.api.nvim_win_get_cursor(win)
  vim.wait(160, function()
    return false
  end, 5)
  assert(
    vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor),
    "new window protection cancels motion"
  )
  vim.wo[win].cursorbind = false
end)

test("visible_target_cancels_pending_scroll", function()
  local lines = {}
  for row = 1, 100 do
    lines[row] = "line " .. row
  end
  local buf = draft(lines)
  vim.api.nvim_win_set_buf(0, buf)
  local win = vim.api.nvim_get_current_win()
  motion.view(win, buf, 80, 0)
  motion.view(win, buf, 2, 0)
  vim.wait(180, function()
    return false
  end, 5)
  assert(
    vim.api.nvim_win_get_cursor(win)[1] == 2,
    "a stale scroll cannot overwrite the latest caret"
  )
end)

test("completed_batch_remains_visible_until_revealed", function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local lines = { "local first = 1", "local second = 2", "return first + second" }
  follow.record_preview(root, {
    toolCallId = "complete",
    tool = "write",
    path = "new.lua",
    line = 3,
    sequence = 1,
    agent = "pi",
    lines = lines,
  })
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.b[buf].agent_lens_preview, "batch opens a draft immediately")
  vim.fn.writefile(lines, root .. "/new.lua")
  follow.record_location(root, {
    call_id = "complete",
    phase = "success",
    tool = "write",
    path = "new.lua",
    line = 1,
    agent = "pi",
  })
  follow.preview_disconnected(root, "complete")
  assert(
    vim.b[buf].agent_lens_preview and vim.api.nvim_buf_is_valid(buf),
    "completion and a closing host socket do not skip the animation"
  )
  assert(
    vim.wait(500, function()
      return not vim.api.nvim_buf_is_valid(buf)
    end, 5),
    "finished draft settles promptly"
  )
  assert(vim.deep_equal(content(0), lines), "settled view uses authoritative disk text")
  assert(vim.api.nvim_win_get_cursor(0)[1] == 3, "settling does not jump back to the first line")
  follow.clear()
  vim.fn.delete(root, "rf")
end)

if #failures > 0 then
  error(table.concat(failures, "\n"))
end
print("motion behavior OK")
vim.cmd("qa!")
