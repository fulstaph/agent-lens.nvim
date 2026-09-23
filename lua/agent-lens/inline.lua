--- Recent read ranges and Git HEAD-to-disk changes in ordinary file buffers.
local M = {}
local uv = vim.uv or vim.loop
local read_ns = vim.api.nvim_create_namespace("agent_lens_read")
local write_ns = vim.api.nvim_create_namespace("agent_lens_write")
local reads = {}
local writes = {}
local enabled = true

local function file_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and (uv.fs_realpath(name) or name) or nil
end

local function mark_range(buf, ns, first, last, group, label)
  local count = vim.api.nvim_buf_line_count(buf)
  if first > count or last < 1 then
    return false
  end
  first, last = math.max(first, 1), math.min(last, count)
  local text = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1]
  vim.api.nvim_buf_set_extmark(buf, ns, first - 1, 0, {
    end_row = last - 1,
    end_col = #text,
    hl_group = group,
    line_hl_group = first == last and group or nil,
    hl_eol = true,
    virt_text = label and { { " READ · " .. label, group } } or nil,
  })
  return true
end

local function render(buf)
  vim.api.nvim_buf_clear_namespace(buf, read_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, write_ns, 0, -1)
  if not enabled or vim.bo[buf].modified then
    return
  end
  local path = file_path(buf)
  if not path then
    return
  end
  local read = reads[path]
  if read then
    if
      not read.range
      or not mark_range(
        buf,
        read_ns,
        read.range.start,
        read.range["end"],
        "AgentLensRead",
        read.agent
      )
    then
      vim.api.nvim_buf_set_extmark(buf, read_ns, 0, 0, {
        virt_text = { { " READ · " .. read.agent, "AgentLensRead" } },
      })
    end
  end
  local write = writes[path]
  if write then
    for _, span in ipairs(write.ranges) do
      mark_range(buf, write_ns, span[1], span[2], "AgentLensWrite")
    end
    for _, line in ipairs(write.deletions) do
      local row = math.max(0, math.min(line - 1, vim.api.nvim_buf_line_count(buf) - 1))
      vim.api.nvim_buf_set_extmark(buf, write_ns, row, 0, {
        virt_text = { { " − deleted", "AgentLensWrite" } },
      })
    end
  end
end

local function render_file(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and file_path(buf) == path then
      render(buf)
    end
  end
end

local function render_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      render(buf)
    end
  end
end

local function changed_lines(diff)
  local ranges, deletions = {}, {}
  for _, hunk in ipairs(diff.hunks) do
    local line, first, last, added, deleted_at = hunk.new_start, nil, nil, false, nil
    for _, text in ipairs(hunk.lines) do
      local prefix = text:sub(1, 1)
      if prefix == "+" then
        added = true
        if not first then
          first = line
        end
        last = line
        line = line + 1
      else
        if first then
          ranges[#ranges + 1] = { first, last }
          first, last = nil, nil
        end
        if prefix == "-" and not deleted_at then
          deleted_at = line
        end
        if prefix == " " then
          line = line + 1
        end
      end
    end
    if first then
      ranges[#ranges + 1] = { first, last }
    end
    if not added and deleted_at then
      deletions[#deletions + 1] = deleted_at
    end
  end
  return { ranges = ranges, deletions = deletions }
end

function M.record_read(root, rel_path, range, agent)
  local path = uv.fs_realpath(root .. "/" .. rel_path)
  if not path then
    return
  end
  reads = vim.tbl_extend("force", {}, reads, { [path] = { range = range, agent = agent } })
  render_file(path)
end

function M.record_write(root, rel_path, diff)
  local path = uv.fs_realpath(root .. "/" .. rel_path)
    or ((uv.fs_realpath(root) or root) .. "/" .. rel_path)
  writes = vim.tbl_extend("force", {}, writes, { [path] = diff and changed_lines(diff) or false })
  render_file(path)
end

function M.setup(opts)
  enabled = opts.enabled
  vim.api.nvim_set_hl(0, "AgentLensRead", { default = true, link = "DiffChange" })
  vim.api.nvim_set_hl(0, "AgentLensWrite", { default = true, link = "DiffAdd" })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter", "TextChanged", "TextChangedI" }, {
    group = vim.api.nvim_create_augroup("AgentLensInline", { clear = true }),
    callback = function(event)
      render(event.buf)
    end,
  })
  render_all()
end

function M.toggle()
  enabled = not enabled
  render_all()
  return enabled
end

function M.clear()
  reads, writes = {}, {}
  render_all()
end

return M
