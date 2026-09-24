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
local outside = vim.fn.tempname()
vim.fn.mkdir(outside, "p")
vim.fn.system({ "ln", "-s", outside .. "/missing-dir", root .. "/dangling" })
assert(vim.v.shell_error == 0, "dangling symlink")

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
local function mark_label(entry)
  return entry.mark[4].virt_text[1][1]
end

local function location(call_id, phase, tool, path, line, sequence)
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
    sequence = sequence,
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
location("dangling-draft", "progress", "edit", "dangling/new.lua", 1, 1)
assert(#all_marks() == 0, "dangling parent symlink does not render")
location("missing-draft", "progress", "edit", "drafted.lua", 1, 1)
local missing_draft = all_marks()
local missing_draft_buf = vim.fn.bufnr(root .. "/drafted.lua")
assert(
  #missing_draft == 1
    and missing_draft[1].buf == missing_draft_buf
    and missing_draft[1].mark[2] == 0
    and mark_label(missing_draft[1]) == "  AGENT · pi · drafting"
    and not vim.bo[missing_draft_buf].modified,
  "missing edit targets render an unmodified drafting buffer"
)
location("missing-draft", "success", "edit", "drafted.lua", 1)
local settled_missing = all_marks()
assert(
  #settled_missing == 1
    and settled_missing[1].buf == missing_draft_buf
    and mark_label(settled_missing[1]) == "  AGENT · pi",
  "missing edit success settles the drafting marker"
)
follow.clear()

location("draft-call", "progress", "edit", "target.lua", 1, 1)
local draft = all_marks()
assert(
  #draft == 1 and draft[1].mark[2] == 0 and mark_label(draft[1]) == "  AGENT · pi · drafting",
  "first progress renders a drafting marker"
)
location("draft-call", "progress", "edit", "target.lua", 120, 2)
local hunk = all_marks()
assert(
  #hunk == 1
    and hunk[1].mark[2] == 119
    and mark_label(hunk[1]) == "  AGENT · pi · drafting"
    and vim.api.nvim_get_current_win() == user_win
    and vim.api.nvim_win_get_cursor(user_win)[1] == 120,
  "higher progress moves one marker without stealing focus"
)
location("draft-call", "progress", "edit", "target.lua", 40, 2)
location("draft-call", "progress", "edit", "target.lua", 30, 1)
local stale_hunk = all_marks()
assert(#stale_hunk == 1 and stale_hunk[1].mark[2] == 119, "duplicate and lower progress is ignored")
location("draft-call", "progress", "edit", "next.lua", 30, 3)
local draft_next = all_marks()
local draft_next_buf = vim.fn.bufnr(root .. "/next.lua")
assert(
  #draft_next == 1
    and draft_next[1].buf == draft_next_buf
    and draft_next[1].mark[2] == 29
    and mark_label(draft_next[1]) == "  AGENT · pi · drafting",
  "next complete file section replaces the single marker"
)
location("draft-call", "start", "edit", "next.lua", nil)
local applying = all_marks()
assert(
  #applying == 1
    and applying[1].mark[2] == 29
    and mark_label(applying[1]) == "  AGENT · pi · applying",
  "matching start transitions the same target to applying"
)
location("other-draft", "progress", "edit", "target.lua", 10, 1)
local execution_marker = all_marks()
assert(
  #execution_marker == 1
    and execution_marker[1].mark[2] == 29
    and mark_label(execution_marker[1]) == "  AGENT · pi · applying",
  "execution target rejects competing progress"
)

location("draft-call", "success", "edit", "next.lua", 35)
local settled = all_marks()
assert(
  #settled == 1 and settled[1].mark[2] == 34 and mark_label(settled[1]) == "  AGENT · pi",
  "success refines and settles the marker"
)

location("call-a", "start", "read", "target.lua", 120)
local target_buf = vim.fn.bufnr(root .. "/target.lua")
assert(target_buf > 0, "follow loads the target buffer")
assert(vim.api.nvim_get_current_win() == user_win, "follow does not steal focus")
assert(vim.api.nvim_win_get_cursor(user_win)[1] == 120, "follow moves cursor to requested line")
assert(vim.api.nvim_win_get_buf(user_win) == target_buf, "follow uses the current editor window")
assert(
  vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(spare_win)) == "",
  "spare window stays untouched"
)
local first_marks = all_marks()
assert(#first_marks == 1, "follow places one global marker")
assert(
  first_marks[1].buf == target_buf and first_marks[1].mark[2] == 119,
  "marker uses requested line"
)
local view = vim.api.nvim_win_call(user_win, function()
  return vim.fn.winsaveview()
end)
local height = vim.api.nvim_win_get_height(user_win)
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
vim.api.nvim_win_set_buf(user_win, user_buf)
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
vim.fn.delete(outside, "rf")
vim.fn.delete(root, "rf")
print("follow core OK")
vim.cmd("qa!")
