-- UI observer for the real Node bridge -> libuv socket -> Follow pipeline.
vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false
vim.o.modeline = false
local root = assert(arg[1])
local config = require("agent-lens.config")
local follow = require("agent-lens.follow")
local feed = require("agent-lens.read_events")
local live = require("agent-lens.live")
config.setup({ enabled = false, reads = { interval_ms = 10 }, follow = { enabled = true } })
follow.setup(config.options.follow)
feed.start(root)
live.start(root)

local function respond(value)
  io.stdout:write(vim.json.encode(value) .. "\n")
  io.stdout:flush()
end

local stopped = false
local input = assert(vim.uv.new_pipe(false))
input:open(0)
local pending = ""
input:read_start(function(err, chunk)
  assert(not err, err)
  if not chunk then
    stopped = true
    return
  end
  pending = pending .. chunk
  while true do
    local boundary = pending:find("\n", 1, true)
    if not boundary then
      break
    end
    local record = pending:sub(1, boundary - 1)
    pending = pending:sub(boundary + 1)
    vim.schedule(function()
      local command = vim.json.decode(record)
      if command.kind == "edit" then
        vim.cmd("edit " .. vim.fn.fnameescape(root .. "/user.lua"))
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved user text" })
      elseif command.kind == "pause" then
        follow.pause("test")
      elseif command.kind == "resume" then
        follow.resume()
      elseif command.kind == "toggle" then
        follow.toggle()
      elseif command.kind == "stop" then
        stopped = true
      end
      local buf = vim.api.nvim_get_current_buf()
      local drafts = {}
      local marks = {}
      for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(candidate) then
          if vim.b[candidate].agent_lens_preview then
            drafts[#drafts + 1] = {
              name = vim.api.nvim_buf_get_name(candidate),
              lines = vim.api.nvim_buf_get_lines(candidate, 0, -1, false),
              modified = vim.bo[candidate].modified,
              modifiable = vim.bo[candidate].modifiable,
            }
          end
          for _, mark in
            ipairs(
              vim.api.nvim_buf_get_extmarks(
                candidate,
                vim.api.nvim_get_namespaces().agent_lens_follow,
                0,
                -1,
                { details = true }
              )
            )
          do
            marks[#marks + 1] = { line = mark[2] + 1, label = mark[4].virt_text[1][1] }
          end
        end
      end
      respond({
        id = command.id,
        name = vim.api.nvim_buf_get_name(buf),
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
        modified = vim.bo[buf].modified,
        drafts = drafts,
        marks = marks,
        control = follow.state().control,
        status = require("agent-lens.status").get(),
        windows = #vim.api.nvim_tabpage_list_wins(0),
      })
    end)
  end
end)
respond({ ready = true })
assert(
  vim.wait(30000, function()
    return stopped
  end, 10),
  "live-preview test timed out"
)
input:read_stop()
input:close()
live.stop()
feed.stop()
follow.clear()
vim.cmd("qa!")
