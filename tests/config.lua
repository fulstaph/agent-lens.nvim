-- Option validation keeps defaults for invalid values instead of failing later.
vim.opt.rtp:append(vim.fn.getcwd())

local config = require("agent-lens.config")
local warnings = {}
vim.notify = function(message, level)
  warnings[#warnings + 1] = { message = message, level = level }
end

config.setup({
  debounce_ms = "fast",
  max_timeline_entries = 0,
  timeline_position = "top",
  reads = { interval_ms = 0, enabled = true },
  follow = { window = "floating", animation_ms = 120, split = { width = -1 } },
  keymaps = { toggle = false, follow = "" },
  filter = { ignore_patterns = { "*.tmp" } },
  agent_name = "codex",
  unknown_option = true,
})
local o = config.options
assert(o.debounce_ms == 150, "wrong type falls back to default")
assert(o.max_timeline_entries == 200, "out-of-range number falls back to default")
assert(o.timeline_position == "right", "unknown enum falls back to default")
assert(o.reads.interval_ms == 100 and o.reads.enabled == true, "nested fields validate separately")
assert(o.follow.window == "current" and o.follow.animation_ms == 120, "valid siblings are kept")
assert(o.follow.split.width == 0, "nested range check")
assert(o.keymaps.toggle == false and o.keymaps.follow == "", "keymaps can be disabled")
assert(vim.deep_equal(o.filter.ignore_patterns, { "*.tmp" }), "lists replace defaults")
assert(o.agent_name == "codex" and o.unknown_option == true, "valid and unknown options pass")
assert(o.diff_source == nil and o.filter.min_change_bytes == nil, "removed options are gone")

assert(#warnings == 1 and warnings[1].level == vim.log.levels.WARN, "one aggregated warning")
for _, path in ipairs({
  "debounce_ms",
  "max_timeline_entries",
  "timeline_position",
  "reads.interval_ms",
  "follow.window",
  "follow.split.width",
}) do
  assert(warnings[1].message:find(path, 1, true), "warning names " .. path)
end

warnings = {}
config.setup({ enabled = false })
assert(#warnings == 0 and config.options.enabled == false, "valid options are silent")
config.setup("not a table")
assert(#warnings == 1 and config.options.debounce_ms == 150, "non-table options use defaults")

for _, invalid in ipairs({ false, 123, "" }) do
  warnings = {}
  config.setup({ watch_dir = invalid })
  assert(config.options.watch_dir == nil and #warnings == 1, "invalid optional directory")
end
for _, invalid in ipairs({ { false }, { 123 }, { glob = "*.tmp" }, { [2] = "*.tmp" } }) do
  warnings = {}
  config.setup({ filter = { ignore_patterns = invalid } })
  assert(#warnings == 1, "invalid ignore list warns")
  assert(
    vim.deep_equal(config.options.filter.ignore_patterns, config.defaults.filter.ignore_patterns)
  )
  assert(
    require("agent-lens.watcher")._is_ignored("file.swp", config.options.filter.ignore_patterns)
  )
end
warnings = {}
config.setup({ watch_dir = "/tmp", filter = { ignore_patterns = {} } })
assert(config.options.watch_dir == "/tmp" and #config.options.filter.ignore_patterns == 0)
assert(#warnings == 0, "valid optional directory and empty ignore list")
assert(config.options.highlights.changed == nil and config.options.highlights.timeline_agent == nil)

print("config validation OK")
vim.cmd("qa!")
