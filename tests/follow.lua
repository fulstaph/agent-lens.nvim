vim.opt.rtp:append(vim.fn.getcwd())

local lens = require("agent-lens")
local feed = require("agent-lens.read_events")
local follow = require("agent-lens.follow")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
assert(vim.fn.system({ "git", "init", root }) ~= "" and vim.v.shell_error == 0, "git init")
local events = root .. "/.git/agent-lens/reads.jsonl"
vim.fn.mkdir(root .. "/.git/agent-lens", "p")
vim.fn.writefile({}, events)

local function write_lines(path, count)
  local lines = {}
  for line = 1, count do
    lines[line] = "line " .. line
  end
  vim.fn.writefile(lines, path)
end

local function marks(buf)
  local namespace = assert(vim.api.nvim_get_namespaces().agent_lens_follow)
  return vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
end

local function all_marks()
  local result = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, mark in ipairs(marks(buf)) do
        result[#result + 1] = { buf = buf, mark = mark }
      end
    end
  end
  return result
end

local function location(call_id, phase, tool, path, line)
  local file = assert(io.open(events, "ab"))
  assert(file:write(vim.json.encode({
    v = 1,
    kind = "location",
    toolCallId = call_id,
    phase = phase,
    tool = tool,
    path = path,
    line = line,
    agent = "pi",
  }) .. "\n"))
  assert(file:close())
  feed.poll()
end

write_lines(root .. "/user.lua", 20)
write_lines(root .. "/target.lua", 200)
write_lines(root .. "/next.lua", 80)

lens.setup({ enabled = false, reads = { enabled = false }, follow = { enabled = true } })
assert(follow.is_enabled(), "setup enables follow")
assert(vim.api.nvim_get_commands({}).AgentLensFollow, "setup registers follow command")
lens.start(root)
assert(feed.is_running(), "follow alone starts the metadata feed")

vim.cmd("edit " .. vim.fn.fnameescape(root .. "/user.lua"))
local user_win = vim.api.nvim_get_current_win()
local user_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(user_win, { 7, 2 })

vim.cmd("rightbelow vsplit")
local spare_win = vim.api.nvim_get_current_win()
vim.cmd("enew")
vim.api.nvim_set_current_win(user_win)
local user_cursor = vim.api.nvim_win_get_cursor(user_win)

location("call-a", "start", "read", "target.lua", 120)
local target_buf = vim.fn.bufnr(root .. "/target.lua")
assert(target_buf > 0, "follow loads the target buffer")
assert(vim.api.nvim_get_current_win() == user_win, "follow does not steal focus")
assert(
  vim.deep_equal(vim.api.nvim_win_get_cursor(user_win), user_cursor),
  "follow preserves user cursor"
)
assert(vim.api.nvim_win_get_buf(spare_win) == target_buf, "follow uses another safe editor window")
local first_marks = all_marks()
assert(#first_marks == 1, "follow places one global marker")
assert(
  first_marks[1].buf == target_buf and first_marks[1].mark[2] == 119,
  "marker uses requested line"
)
local view = vim.api.nvim_win_call(spare_win, function()
  return vim.fn.winsaveview()
end)
local height = vim.api.nvim_win_get_height(spare_win)
assert(view.topline <= 120 and view.topline + height - 1 >= 120, "target line is visible")

location("call-a", "success", "read", "target.lua", 130)
local refined = all_marks()
assert(#refined == 1 and refined[1].mark[2] == 129, "matching success refines one marker")

location("call-old", "start", "edit", "target.lua", nil)
location("call-new", "start", "edit", "next.lua", nil)
location("call-old", "success", "edit", "target.lua", 25)
local next_buf = vim.fn.bufnr(root .. "/next.lua")
local latest = all_marks()
assert(#latest == 1 and latest[1].buf == next_buf, "older completion cannot replace newer call")
location("call-new", "error", "edit", nil, nil)
assert(#all_marks() == 0, "matching error clears active marker")
location("call-old", "success", "edit", "target.lua", 25)
assert(#all_marks() == 0, "completion before cleared active call stays stale")

location("call-toggle-a", "start", "read", "target.lua", 50)
assert(#all_marks() == 1, "enabled follow renders")
assert(not follow.toggle(), "toggle disables follow")
assert(#all_marks() == 0, "disabling clears only follow marker")
location("call-toggle-b", "start", "read", "next.lua", 20)
assert(#all_marks() == 0, "disabled follow tracks without rendering")
assert(follow.toggle(), "toggle enables follow")
local replayed = all_marks()
assert(
  #replayed == 1 and replayed[1].buf == next_buf and replayed[1].mark[2] == 19,
  "re-enable renders latest target"
)

lens.clear()
assert(#all_marks() == 0, "AgentLensClear removes follow marker")
vim.cmd("AgentLensFollow")
assert(not follow.is_enabled() and not feed.is_running(), "command disables follow-only feed")
vim.cmd("AgentLensFollow")
assert(follow.is_enabled() and feed.is_running(), "command restarts follow-only feed")
if vim.api.nvim_win_is_valid(spare_win) then
  vim.api.nvim_win_close(spare_win, true)
end
vim.api.nvim_set_current_win(user_win)
vim.api.nvim_buf_set_lines(user_buf, 0, 1, false, { "unsaved user text" })
assert(vim.bo[user_buf].modified, "fixture buffer is modified")
local windows_before = #vim.api.nvim_tabpage_list_wins(0)
local contents_before = vim.api.nvim_buf_get_lines(user_buf, 0, 1, false)[1]
location("call-safe", "start", "read", "target.lua", 60)
assert(vim.api.nvim_get_current_win() == user_win, "modified-buffer fallback keeps focus")
assert(vim.api.nvim_win_get_buf(user_win) == user_buf, "modified buffer is not replaced")
assert(
  vim.api.nvim_buf_get_lines(user_buf, 0, 1, false)[1] == contents_before,
  "unsaved text is preserved"
)
assert(#vim.api.nvim_tabpage_list_wins(0) == windows_before + 1, "follow opens a safe split")

follow.clear()
location("call-create", "start", "write", "created.lua", 1)
assert(#all_marks() == 0, "missing write target waits for creation")
write_lines(root .. "/created.lua", 3)
follow.file_changed(root, "created.lua")
local created_buf = vim.fn.bufnr(root .. "/created.lua")
local created = all_marks()
assert(
  #created == 1 and created[1].buf == created_buf and created[1].mark[2] == 0,
  "matching file creation completes follow"
)

vim.bo[user_buf].modified = false
lens.stop()
assert(#all_marks() == 0, "AgentLensStop removes follow marker")
assert(not feed.is_running(), "AgentLensStop releases metadata feed")
vim.fn.delete(root, "rf")
print("follow core OK")
vim.cmd("qa!")
