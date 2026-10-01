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
---@field _ignored_directories? fun(rel_dir: string): table<string, boolean> Ignored directory provider

---@type AgentLensWatcher|nil
M._instance = nil

local uv = vim.uv

local function remove_watcher(watcher, dir)
  local handle = watcher.watchers[dir]
  if not handle then
    return
  end
  if not handle:is_closing() then
    handle:stop()
    handle:close()
  end
  watcher.watchers[dir] = nil
end

local compiled_globs = {}

--- Translate a glob into an anchored Lua pattern. `*` and `?` stay within one
--- path segment, `[...]`/`[!...]` are character classes, everything else is literal.
---@param glob string
---@return string
local function glob_pattern(glob)
  if compiled_globs[glob] then
    return compiled_globs[glob]
  end
  local out, i = { "^" }, 1
  while i <= #glob do
    local c = glob:sub(i, i)
    local close = c == "[" and glob:find("]", i + 2, true)
    if c == "*" then
      out[#out + 1] = "[^/]*"
    elseif c == "?" then
      out[#out + 1] = "[^/]"
    elseif close then
      local body = glob:sub(i + 1, close - 1)
      local negate = body:sub(1, 1) == "!"
      if negate then
        body = body:sub(2)
      end
      out[#out + 1] = "[" .. (negate and "^" or "") .. body:gsub("[%%%^]", "%%%0") .. "]"
      i = close
    else
      out[#out + 1] = c:match("%p") and "%" .. c or c
    end
    i = i + 1
  end
  out[#out + 1] = "$"
  compiled_globs[glob] = table.concat(out)
  return compiled_globs[glob]
end

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
      local lua_pat = glob_pattern(pat)
      if path:match(lua_pat) or basename:match(lua_pat) then
        return true
      end
    end
  end
  return false
end

M._is_ignored = is_ignored

local function schedule_debounce(watcher, full_path, rel_path, events)
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
      if not watcher.running or watcher._debounce_timers[full_path] ~= timer then
        return
      end
      timer:stop()
      timer:close()
      watcher._debounce_timers[full_path] = nil

      local stat = uv.fs_stat(full_path)
      if stat and stat.type == "file" then
        watcher._on_change(rel_path, events)
      elseif not stat and events.rename then
        watcher._on_change(rel_path, { rename = true, deleted = true })
      end
    end)
  )
end

---@return boolean|nil nil if allocation fails, false if start fails
local function attach_watcher(watcher, dir, recursive, on_directory)
  local handle = uv.new_fs_event()
  if not handle then
    return nil
  end

  local ok = handle:start(
    dir,
    { recursive = recursive },
    vim.schedule_wrap(function(err, filename, events)
      if not watcher.running or err or not filename then
        remove_watcher(watcher, dir)
        return
      end

      local full_path = dir .. "/" .. filename
      local rel_path = recursive and filename or full_path:sub(#watcher.root + 2)

      if is_ignored(rel_path, config.options.filter.ignore_patterns) then
        return
      end

      if on_directory then
        local stat = uv.fs_stat(full_path)
        if stat and stat.type == "directory" then
          on_directory(watcher, full_path)
          return
        end
      end

      schedule_debounce(watcher, full_path, rel_path, events)
    end)
  )

  if ok then
    watcher.watchers[dir] = handle
    return true
  end
  handle:close()
  return false
end

local watch_dir_recursive

--- Watch a directory tree, skipping directories the provider reports as ignored.
---@param watcher AgentLensWatcher
---@param dir string
local function watch_tree(watcher, dir)
  local rel = dir == watcher.root and "" or dir:sub(#watcher.root + 2)
  local skip = watcher._ignored_directories and watcher._ignored_directories(rel) or {}
  if not skip[rel] then
    watch_dir_recursive(watcher, dir, skip)
  end
end

--- Scan a directory and attach watchers to all subdirectories.
---@param watcher AgentLensWatcher
---@param dir string
---@param skip table<string, boolean> Root-relative directories not to watch
function watch_dir_recursive(watcher, dir, skip)
  if not watcher.running or watcher.watchers[dir] then
    return
  end
  -- A missing handle skips this subtree; a failed start still scans its children.
  if attach_watcher(watcher, dir, false, watch_tree) == nil then
    return
  end

  -- Recurse into subdirectories
  local scanner = uv.fs_scandir(dir)
  if scanner then
    while true do
      local name, typ = uv.fs_scandir_next(scanner)
      if not name then
        break
      end
      local child = dir .. "/" .. name
      if
        typ == "directory"
        and not is_ignored(name, config.options.filter.ignore_patterns)
        and not skip[child:sub(#watcher.root + 2)]
      then
        watch_dir_recursive(watcher, child, skip)
      end
    end
  end
end

--- Start watching a directory tree.
---@param root string Root directory to watch
---@param on_change fun(path: string, events: table) Callback when a file changes
---@param opts? {ignored_directories?: fun(rel_dir: string): table<string, boolean>} Directories to leave unwatched on per-directory platforms
---@return AgentLensWatcher
function M.start(root, on_change, opts)
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
    _ignored_directories = opts and opts.ignored_directories,
  }

  -- On macOS, libuv supports recursive watching natively via FSEvents.
  -- Use a single recursive watcher for the root on macOS; fallback to per-dir on Linux.
  if jit and jit.os == "OSX" then
    if attach_watcher(watcher, root, true) == false then
      watch_tree(watcher, root)
    end
  else
    watch_tree(watcher, root)
  end

  M._instance = watcher
  return watcher
end

--- Stop the active watcher and clean up all handles.
function M.stop()
  local watcher = M._instance
  if not watcher then
    return
  end

  watcher.running = false

  for dir in pairs(watcher.watchers) do
    remove_watcher(watcher, dir)
  end

  for path, timer in pairs(watcher._debounce_timers) do
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    watcher._debounce_timers[path] = nil
  end

  M._instance = nil
end

--- Check if the watcher is currently running.
---@return boolean
function M.is_running()
  return M._instance ~= nil and M._instance.running
end

return M
