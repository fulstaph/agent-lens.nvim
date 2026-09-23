--- File system watcher using vim.uv (libuv).
--- Watches a directory tree for file changes and emits events.

local config = require("agent-lens.config")

local M = {}

---@class AgentLensWatcher
---@field watchers table<string, userdata> Active fs_event handles keyed by dir path
---@field root string Root directory being watched
---@field running boolean Whether the watcher is active
---@field _debounce_timers table<string, userdata> Pending debounce timers per file
---@field _on_change fun(path: string, events: table) Callback for file changes

---@type AgentLensWatcher|nil
M._instance = nil

local uv = vim.uv or vim.loop

--- Check if a path matches any ignore pattern.
---@param path string Relative path from root
---@param patterns string[] Glob patterns
---@return boolean
local function is_ignored(path, patterns)
  local basename = path:match("[^/]+$") or path
  for _, pat in ipairs(patterns) do
    if pat:sub(-3) == "/**" then
      local dir = pat:sub(1, -4)
      if
        path == dir
        or path:sub(1, #dir + 1) == dir .. "/"
        or path:find("/" .. dir .. "/", 1, true)
      then
        return true
      end
    else
      local lua_pat = "^" .. pat:gsub("%.", "%%."):gsub("%*", "[^/]*"):gsub("%?", "[^/]") .. "$"
      if path:match(lua_pat) or basename:match(lua_pat) then
        return true
      end
    end
  end
  return false
end

--- Scan a directory and attach watchers to all subdirectories.
---@param watcher AgentLensWatcher
---@param dir string
local function watch_dir_recursive(watcher, dir)
  if watcher.watchers[dir] then
    return
  end

  local handle = uv.new_fs_event()
  if not handle then
    return
  end

  local ok = handle:start(
    dir,
    { recursive = false },
    vim.schedule_wrap(function(err, filename, events)
      if err then
        return
      end
      if not filename then
        return
      end

      local full_path = dir .. "/" .. filename
      local rel_path = full_path:sub(#watcher.root + 2)

      if is_ignored(rel_path, config.options.filter.ignore_patterns) then
        return
      end

      -- Check if it's a new directory — if so, watch it too
      local stat = uv.fs_stat(full_path)
      if stat and stat.type == "directory" then
        watch_dir_recursive(watcher, full_path)
        return
      end

      -- Debounce: cancel any pending timer for this file
      if watcher._debounce_timers[full_path] then
        watcher._debounce_timers[full_path]:stop()
        watcher._debounce_timers[full_path]:close()
        watcher._debounce_timers[full_path] = nil
      end

      local timer = uv.new_timer()
      if not timer then
        return
      end
      watcher._debounce_timers[full_path] = timer
      timer:start(
        config.options.debounce_ms,
        0,
        vim.schedule_wrap(function()
          timer:stop()
          timer:close()
          watcher._debounce_timers[full_path] = nil

          -- Verify file still exists (not a transient temp file)
          local final_stat = uv.fs_stat(full_path)
          if final_stat and final_stat.type == "file" then
            watcher._on_change(rel_path, events)
          elseif not final_stat and events.rename then
            -- File was deleted
            watcher._on_change(rel_path, { rename = true, deleted = true })
          end
        end)
      )
    end)
  )

  if ok then
    watcher.watchers[dir] = handle
  else
    handle:close()
  end

  -- Recurse into subdirectories
  local scanner = uv.fs_scandir(dir)
  if scanner then
    while true do
      local name, typ = uv.fs_scandir_next(scanner)
      if not name then
        break
      end
      if typ == "directory" and not is_ignored(name, config.options.filter.ignore_patterns) then
        local child = dir .. "/" .. name
        watch_dir_recursive(watcher, child)
      end
    end
  end
end

--- Start watching a directory tree.
---@param root string Root directory to watch
---@param on_change fun(path: string, events: table) Callback when a file changes
---@return AgentLensWatcher
function M.start(root, on_change)
  if M._instance and M._instance.running then
    M.stop()
  end

  ---@type AgentLensWatcher
  local watcher = {
    watchers = {},
    root = root,
    running = true,
    _debounce_timers = {},
    _on_change = on_change,
  }

  -- On macOS, libuv supports recursive watching natively via FSEvents.
  -- Use a single recursive watcher for the root on macOS; fallback to per-dir on Linux.
  if jit and jit.os == "OSX" then
    local handle = uv.new_fs_event()
    if handle then
      local ok = handle:start(
        root,
        { recursive = true },
        vim.schedule_wrap(function(err, filename, events)
          if err or not filename then
            return
          end

          if is_ignored(filename, config.options.filter.ignore_patterns) then
            return
          end

          local full_path = root .. "/" .. filename

          -- Debounce
          if watcher._debounce_timers[full_path] then
            watcher._debounce_timers[full_path]:stop()
            watcher._debounce_timers[full_path]:close()
            watcher._debounce_timers[full_path] = nil
          end

          local timer = uv.new_timer()
          if not timer then
            return
          end
          watcher._debounce_timers[full_path] = timer
          timer:start(
            config.options.debounce_ms,
            0,
            vim.schedule_wrap(function()
              timer:stop()
              timer:close()
              watcher._debounce_timers[full_path] = nil

              local stat = uv.fs_stat(full_path)
              if stat and stat.type == "file" then
                watcher._on_change(filename, events)
              elseif not stat and events.rename then
                watcher._on_change(filename, { rename = true, deleted = true })
              end
            end)
          )
        end)
      )

      if ok then
        watcher.watchers[root] = handle
      else
        handle:close()
        -- Fallback to per-dir
        watch_dir_recursive(watcher, root)
      end
    end
  else
    watch_dir_recursive(watcher, root)
  end

  M._instance = watcher
  return watcher
end

--- Stop the active watcher and clean up all handles.
function M.stop()
  local w = M._instance
  if not w then
    return
  end

  w.running = false

  for path, handle in pairs(w.watchers) do
    if not handle:is_closing() then
      handle:stop()
      handle:close()
    end
    w.watchers[path] = nil
  end

  for path, timer in pairs(w._debounce_timers) do
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    w._debounce_timers[path] = nil
  end

  M._instance = nil
end

--- Check if the watcher is currently running.
---@return boolean
function M.is_running()
  return M._instance ~= nil and M._instance.running
end

return M
