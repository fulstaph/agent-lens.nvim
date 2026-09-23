vim.opt.rtp:append(vim.fn.getcwd())
vim.o.autoread = true

local lens = require("agent-lens")
local root = vim.fn.tempname()
assert(vim.fn.system({ "git", "init", root }) ~= "" and vim.v.shell_error == 0)
local file = root .. "/sample.lua"
vim.fn.writefile({ "one", "two", "three", "four" }, file)
vim.fn.system({ "git", "-C", root, "add", "sample.lua" })
assert(vim.v.shell_error == 0)
vim.fn.system({
  "git",
  "-C",
  root,
  "-c",
  "user.name=CI",
  "-c",
  "user.email=ci@example.test",
  "commit",
  "-qm",
  "fixture",
})
assert(vim.v.shell_error == 0)

lens.setup({ enabled = false, reads = { enabled = true }, inline = { enabled = true } })
lens.start(root)
vim.fn.mkdir(root .. "/.git/agent-lens", "p")
local log = root .. "/.git/agent-lens/reads.jsonl"
local function emit(event)
  local out = assert(io.open(log, "ab"))
  assert(out:write(vim.json.encode(event) .. "\n"))
  assert(out:close())
  require("agent-lens.read_events").poll()
end
local function marks(buf, namespace)
  return vim.api.nvim_buf_get_extmarks(
    buf,
    vim.api.nvim_get_namespaces()[namespace],
    0,
    -1,
    { details = true }
  )
end

-- A read before the file opens should decorate the source buffer when entered.
emit({ v = 1, kind = "read", path = "sample.lua", agent = "pi", range = { start = 2, ["end"] = 3 } })
vim.cmd("edit " .. vim.fn.fnameescape(file))
local buf = vim.api.nvim_get_current_buf()
local read_marks = marks(buf, "agent_lens_read")
assert(
  #read_marks == 1 and read_marks[1][2] == 1 and read_marks[1][4].end_row == 2,
  "read range highlights lines 2-3"
)
assert(read_marks[1][4].hl_group == "AgentLensRead", "read highlight group")

-- Write decorations target changed new-file lines, not unchanged context.
vim.fn.writefile({ "one", "TWO", "three", "four", "five" }, file)
assert(
  vim.wait(2000, function()
    return #marks(buf, "agent_lens_write") == 2
  end, 20),
  "filesystem edit highlights changed lines"
)
local write_marks = marks(buf, "agent_lens_write")
assert(write_marks[1][2] == 1 and write_marks[2][2] == 4, "write marks exclude context")

-- A file-level read is labelled without falsely claiming every line was read.
emit({ v = 1, kind = "read", path = "sample.lua", agent = "pi" })
read_marks = marks(buf, "agent_lens_read")
assert(
  #read_marks == 1 and read_marks[1][2] == 0 and read_marks[1][4].virt_text,
  "unknown range shows file-level label"
)
emit({
  v = 1,
  kind = "read",
  path = "sample.lua",
  agent = "pi",
  range = { start = 100, ["end"] = 105 },
})
read_marks = marks(buf, "agent_lens_read")
assert(
  #read_marks == 1 and read_marks[1][2] == 0 and read_marks[1][4].virt_text,
  "outdated range falls back to a file-level label"
)

vim.cmd("AgentLensInlineToggle")
assert(
  #marks(buf, "agent_lens_read") == 0 and #marks(buf, "agent_lens_write") == 0,
  "toggle hides both overlays"
)
vim.cmd("AgentLensInlineToggle")
assert(
  #marks(buf, "agent_lens_read") == 1 and #marks(buf, "agent_lens_write") == 2,
  "toggle restores latest activity"
)

-- A deletion with no replacement has an anchor, not a misleading highlighted row.
vim.fn.writefile({ "one", "two", "three" }, file)
local deletion_marks
assert(
  vim.wait(2000, function()
    deletion_marks = marks(buf, "agent_lens_write")
    return #deletion_marks == 1
      and deletion_marks[1][2] == 2
      and deletion_marks[1][4].virt_text ~= nil
  end, 20),
  "pure deletion uses a virtual-text anchor"
)

-- Unsaved local edits must not be mistaken for the on-disk agent activity.
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
assert(
  #marks(buf, "agent_lens_read") == 0 and #marks(buf, "agent_lens_write") == 0,
  "modified buffer hides disk-relative marks"
)
vim.cmd("edit!")
assert(
  #marks(buf, "agent_lens_read") == 1 and #marks(buf, "agent_lens_write") == 1,
  "reopening restores disk marks"
)

vim.fn.writefile({ "one", "two", "three", "four" }, file)
assert(
  vim.wait(2000, function()
    return #marks(buf, "agent_lens_write") == 0
  end, 20),
  "reverting to HEAD removes stale write marks"
)
lens.clear()
assert(
  #marks(buf, "agent_lens_read") == 0 and #marks(buf, "agent_lens_write") == 0,
  "clear removes activity"
)

-- A newly created, untracked file also shows its lines, then clears on removal.
local new_file = root .. "/new.lua"
vim.fn.writefile({ "new content" }, new_file)
vim.cmd("edit " .. vim.fn.fnameescape(new_file))
local new_buf = vim.api.nvim_get_current_buf()
assert(
  vim.wait(2000, function()
    return #marks(new_buf, "agent_lens_write") == 1
  end, 20),
  "untracked file highlights new content"
)
vim.fn.delete(new_file)
assert(
  vim.wait(2000, function()
    return #marks(new_buf, "agent_lens_write") == 0
  end, 20),
  "removed file clears stale marks"
)

lens.stop()
vim.fn.delete(root, "rf")
print("inline activity OK")
vim.cmd("qa!")
