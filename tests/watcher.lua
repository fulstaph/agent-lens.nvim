vim.opt.rtp:append(vim.fn.getcwd())

local config = require("agent-lens.config")
local native_uv = vim.uv
local native_schedule = vim.schedule
local native_jit = jit
local failures = {}
config.setup({ enabled = false, debounce_ms = 5, filter = { ignore = {} } })

-- Control the libuv-to-main-loop boundary; file reads and directory scans stay real.
local function fixture(platform, run)
  local root = vim.fn.tempname()
  local replacement = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.mkdir(replacement, "p")
  vim.fn.writefile({ "original" }, root .. "/source.txt")
  vim.fn.writefile({ "replacement" }, replacement .. "/source.txt")
  local queue, timers, events, deliveries = {}, {}, {}, {}
  local function flush()
    local callback = assert(table.remove(queue, 1), "expected queued callback")
    callback()
  end
  local function handle()
    local closing = false
    return {
      stop = function() end,
      close = function()
        assert(not closing, "handle is already closing")
        closing = true
      end,
      is_closing = function()
        return closing
      end,
    }
  end
  local uv = setmetatable({
    new_fs_event = function()
      local event = handle()
      event.start = function(_, dir, _, callback)
        events[dir] = callback
        return 0
      end
      return event
    end,
    new_timer = function()
      local timer = handle()
      timer.start = function(_, _, _, callback)
        timer.fire = callback
      end
      timers[#timers + 1] = timer
      return timer
    end,
  }, { __index = native_uv })
  vim.uv = uv
  vim.schedule = function(callback)
    queue[#queue + 1] = callback
  end
  _G.jit = setmetatable({ os = platform }, { __index = native_jit })
  package.loaded["agent-lens.watcher"] = nil
  local watcher = require("agent-lens.watcher")
  local function deliver(path, flags)
    deliveries[#deliveries + 1] = { path = path, deleted = flags.deleted }
  end
  watcher.start(root, deliver)
  local ctx = {
    root = root,
    replacement = replacement,
    watcher = watcher,
    timers = timers,
    deliveries = deliveries,
    flush = flush,
    emit = function(dir, path, flags)
      assert(events[dir], "directory is watched")(nil, path, flags or { change = true })
    end,
    drain = function()
      while #queue > 0 do
        flush()
      end
    end,
    deliver = deliver,
  }
  local ok, err = xpcall(function()
    run(ctx)
  end, debug.traceback)
  watcher.stop()
  vim.uv = native_uv
  vim.schedule = native_schedule
  _G.jit = native_jit
  package.loaded["agent-lens.watcher"] = nil
  vim.fn.delete(root, "rf")
  vim.fn.delete(replacement, "rf")
  return ok, err
end

local cases = {
  replaced_expiry = function(ctx)
    ctx.emit(ctx.root, "source.txt")
    ctx.flush()
    ctx.emit(ctx.root, "source.txt")
    ctx.timers[1].fire()
    ctx.flush() -- New event replaces the timer before its queued expiry runs.
    ctx.flush()
    ctx.timers[2].fire()
    ctx.drain()
    assert(
      #ctx.deliveries == 1 and ctx.deliveries[1].path == "source.txt",
      "only the latest change is delivered"
    )
  end,
  stopped_expiry = function(ctx)
    ctx.emit(ctx.root, "source.txt")
    ctx.flush()
    ctx.timers[1].fire()
    ctx.watcher.stop()
    ctx.drain()
    assert(#ctx.deliveries == 0, "queued expiry after stop cannot deliver")
  end,
  restarted_event = function(ctx)
    ctx.emit(ctx.root, "source.txt")
    ctx.watcher.stop()
    ctx.watcher.start(ctx.replacement, ctx.deliver)
    ctx.drain()
    for _, timer in ipairs(ctx.timers) do
      timer.fire()
    end
    ctx.drain()
    assert(#ctx.deliveries == 0, "old-root event cannot leak into restarted watcher")
    ctx.emit(ctx.replacement, "source.txt")
    ctx.flush()
    ctx.timers[#ctx.timers].fire()
    ctx.drain()
    assert(#ctx.deliveries == 1, "replacement watcher still delivers new-root changes")
  end,
  directory_after_stop = function(ctx)
    vim.fn.mkdir(ctx.root .. "/nested", "p")
    ctx.emit(ctx.root, "nested", { rename = true })
    ctx.watcher.stop()
    ctx.drain()
    -- A queued directory event must not create new watchers after shutdown.
    local delivered = pcall(ctx.emit, ctx.root .. "/nested", "later.txt")
    assert(not delivered, "stopped watcher does not resurrect directory watches")
    assert(#ctx.deliveries == 0, "stopped directory event is not delivered")
  end,
  changed_and_deleted = function(ctx)
    ctx.emit(ctx.root, "source.txt")
    ctx.flush()
    ctx.timers[#ctx.timers].fire()
    ctx.drain()
    assert(
      #ctx.deliveries == 1 and not ctx.deliveries[1].deleted,
      "existing file change is delivered"
    )
    vim.fn.delete(ctx.root .. "/source.txt")
    ctx.emit(ctx.root, "source.txt", { rename = true })
    ctx.flush()
    ctx.timers[#ctx.timers].fire()
    ctx.drain()
    assert(#ctx.deliveries == 2 and ctx.deliveries[2].deleted, "file deletion is delivered")
  end,
}

for _, platform in ipairs({ "OSX", "Linux" }) do
  for name, run in pairs(cases) do
    local ok, err = fixture(platform, run)
    if ok then
      print("PASS " .. platform .. " " .. name)
    else
      failures[#failures + 1] = platform .. " " .. name .. ": " .. err
      print("FAIL " .. failures[#failures])
    end
  end
end
assert(#failures == 0, table.concat(failures, "\n"))
print("watcher lifecycle OK")
vim.cmd("qa!")
