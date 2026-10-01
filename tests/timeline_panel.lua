vim.opt.rtp:append(vim.fn.getcwd())
local config = require("agent-lens.config")
config.setup({ enabled = false, max_timeline_entries = 20, timeline_width = 30 })
local t = require("agent-lens.timeline")
local panel = require("agent-lens.panel")
local ok, err = xpcall(function()
  local range = { start = 2, ["end"] = 4 }
  t.add({ rel_path = "a.lua", status = "modified", stats = { added = 3, removed = 1 } })
  t.add({ rel_path = "a.lua", status = "modified", stats = { added = 5, removed = 2 } })
  local read = t.add({ rel_path = "a.lua", kind = "read", status = "read", range = range })
  range.start = 99
  assert(read.range.start == 2, "read_range_survives_storage")
  assert(t.summary().added == 5 and t.summary().removed == 2, "latest_edit_stats_are_not_summed")
  panel.setup({ view = "files", filter = "all" })
  local success = false
  panel.set_actions({
    open = function()
      return success
    end,
    browse = function() end,
  })
  panel.open()
  assert(panel.selected().kind ~= "read", "group prefers edit")
  assert(#panel.selected_ids() == 3 and t.summary().unread == 3)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
  assert(t.summary().unread == 3, "failed open remains unread")
  success = true
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
  assert(t.summary().unread == 0, "successful group opens acknowledge matching events")
  panel.set_filter("reads")
  assert(panel.selected().id == read.id)
  panel.set_filter("all")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "xt", false)
  panel.move(1)
  assert(panel.selected().id == read.id, "expanded newest child keeps its identity")
  t.add({ rel_path = "a.lua", status = "modified", stats = { added = 7, removed = 1 } })
  panel.render()
  assert(panel.selected().id == read.id, "new child does not displace selected event")
  vim.api.nvim_feedkeys("g", "xt", false)
  assert(panel.selected().id == read.id, "flat view preserves event ID")
  vim.api.nvim_feedkeys("g", "xt", false)
  panel.set_filter("edits")
  assert(panel.selected().kind ~= "read", "filter falls back to file group")
  panel.set_filter("all")
  vim.api.nvim_feedkeys("m", "xt", false)
  assert(t.summary().unread == 0, "mark all seen")
  for i = 1, 8 do
    t.add({
      rel_path = "file" .. i .. ".lua",
      status = "modified",
      stats = { added = i, removed = 0 },
    })
  end
  panel.render()
  panel.move(4)
  local selected = panel.selected().rel_path
  local before = vim.api.nvim_win_call(panel._win, vim.fn.winsaveview)
  t.add({ rel_path = "new.lua", status = "added", stats = { added = 1, removed = 0 } })
  panel.render()
  local after = vim.api.nvim_win_call(panel._win, vim.fn.winsaveview)
  assert(panel.selected().rel_path == selected, "stable_selection_and_screen_anchor")
  assert(before.lnum - before.topline == after.lnum - after.topline, "screen anchor stable")
  t.add({ rel_path = "long/π🌱/100%/éééééééééééééé.lua", status = "modified" })
  panel.render()
  for _, line in ipairs(vim.api.nvim_buf_get_lines(panel._buf, 0, -1, false)) do
    assert(
      vim.fn.iconv(line, "utf-8", "utf-8") == line
        and vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(panel._win),
      "unicode_percent_narrow_paths"
    )
  end
  config.options.max_timeline_entries = 2
  t.add({ rel_path = "end.lua", status = "modified" })
  t.add({ rel_path = "last.lua", status = "modified" })
  assert(#t.entries == 2 and t.summary().unread == 2)
  t.clear()
  panel.render()
  assert(panel.selected() == nil and next(t.unread_ids()) == nil, "retention_and_clear")
  print("timeline panel behavior OK")
end, debug.traceback)
panel.close()
if not ok then
  error(err)
end
vim.cmd("qa!")
