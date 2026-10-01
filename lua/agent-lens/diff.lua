--- Safe current HEAD-to-disk comparisons.
local M = {}
local paths = require("agent-lens.paths")
-- Coroutines started by M.async yield on Git instead of blocking the editor.
local async_callbacks = {}
local function resume(thread, ...)
  local ok, result, err = coroutine.resume(thread, ...)
  if coroutine.status(thread) ~= "dead" then
    return
  end
  local callback = async_callbacks[thread]
  async_callbacks[thread] = nil
  -- Deliver outside the coroutine so callbacks never yield or nest resumes.
  vim.schedule(function()
    if ok then
      callback(result, err)
    else
      callback(nil, tostring(result))
    end
  end)
end
local function git(root, args, opts)
  opts = opts or {}
  local command = { "git", "-C", root }
  if opts.literal ~= false then
    table.insert(command, 2, "--literal-pathspecs")
  end
  vim.list_extend(command, args)
  local system_opts = { text = false, stdin = opts.stdin }
  local thread = coroutine.running()
  if not (thread and async_callbacks[thread]) then
    return vim.system(command, system_opts):wait()
  end
  local started, err = pcall(vim.system, command, system_opts, function(result)
    vim.schedule(function()
      resume(thread, result)
    end)
  end)
  if not started then
    return { code = -1, stdout = "", stderr = tostring(err) }
  end
  return coroutine.yield()
end
--- Run a function from this module without blocking the editor.
--- Git calls inside it yield until their process exits.
---@param fn fun(...): any, any
---@param callback fun(result: any, err: string|nil) Scheduled on the main loop
---@param ... any Arguments for fn
function M.async(fn, callback, ...)
  local thread = coroutine.create(fn)
  async_callbacks[thread] = callback
  resume(thread, ...)
end
local function lines(text)
  if text == "" then
    return {}
  end
  local result = vim.split(text, "\n", { plain = true })
  if result[#result] == "" then
    table.remove(result)
  end
  for i, line in ipairs(result) do
    result[i] = line:gsub("\r$", "")
  end
  return result
end
local function has_head(root)
  return git(root, { "rev-parse", "--verify", "HEAD^{commit}" }).code == 0
end
--- Detect the repository for a directory.
---@param path? string
---@return string|nil
function M.git_root(path)
  local result = git(path or vim.fn.getcwd(), { "rev-parse", "--show-toplevel" })
  if result.code ~= 0 then
    return nil
  end
  local directory = result.stdout:gsub("\n$", "")
  return vim.uv.fs_realpath(directory)
end
--- Check index tracking without interpreting a path as flags or a pattern.
---@param root string
---@param path string
---@return boolean
function M.is_tracked(root, path)
  if not paths.resolve(root, path, true) then
    return false
  end
  return git(root, { "ls-files", "--error-unmatch", "--", path }).code == 0
end
--- Read an existing HEAD blob after repository path validation.
---@param root string
---@param path string
---@return string[]|nil
function M.head_contents(root, path)
  if not paths.resolve(root, path, true) then
    return nil
  end
  local result = git(root, { "show", "HEAD:./" .. path })
  if result.code ~= 0 or result.stdout:find("%z") then
    return nil
  end
  return lines(result.stdout)
end
--- Read disk only through a safe file target.
---@param root string
---@param path string
---@return string[]|nil
function M.working_contents(root, path)
  local full = paths.resolve(root, path, false)
  if not full then
    return nil
  end
  local file = io.open(full, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  if text:find("%z") then
    return nil
  end
  return lines(text)
end
---@class DiffHunk
---@field old_start integer Start line in old file (1-based)
---@field old_count integer Number of lines from old file
---@field new_start integer Start line in new file (1-based)
---@field new_count integer Number of lines from new file
---@field header string The @@ header line
---@field lines string[] Diff lines (prefixed with +, -, or space)

---@class FileDiff
---@field rel_path string Relative file path
---@field status "modified"|"added"|"deleted"|"renamed" File status
---@field hunks DiffHunk[] List of hunks
---@field stats {added: integer, removed: integer} Line counts
---@field raw string[] Raw unified diff lines

--- Parse a unified diff into structured hunks and line counts.
---@param diff_lines string[] Raw diff output lines
---@return DiffHunk[]
---@return {added: integer, removed: integer}
local function parse_hunks(diff_lines)
  local hunks = {}
  local stats = { added = 0, removed = 0 }
  local current_hunk = nil

  for _, line in ipairs(diff_lines) do
    local prefix = line:sub(1, 1)
    local old_s, old_c, new_s, new_c = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_s then
      current_hunk = {
        old_start = tonumber(old_s),
        old_count = tonumber(old_c) or 1,
        new_start = tonumber(new_s),
        new_count = tonumber(new_c) or 1,
        header = line,
        lines = {},
      }
      hunks[#hunks + 1] = current_hunk
    elseif current_hunk and (prefix == "+" or prefix == "-" or prefix == " ") then
      current_hunk.lines[#current_hunk.lines + 1] = line
      if prefix == "+" then
        stats.added = stats.added + 1
      elseif prefix == "-" then
        stats.removed = stats.removed + 1
      end
    end
  end

  return hunks, stats
end

--- Compute a current safe text comparison, with explicit unavailable errors.
---@param root string
---@param path string
---@return FileDiff|nil
---@return string|nil
function M.review(root, path)
  local full = paths.resolve(root, path, true)
  if not full then
    return nil, "Unsafe or unavailable review target"
  end
  if not has_head(root) then
    return nil, "HEAD baseline unavailable; create the first commit before reviewing"
  end
  local head = git(root, { "show", "HEAD:./" .. path })
  local exists = head.code == 0
  if exists and head.stdout:find("%z") then
    return nil, "Binary file cannot be reviewed as text"
  end
  local disk = vim.uv.fs_stat(full)
  if disk then
    local file = io.open(full, "rb")
    if not file then
      return nil, "Cannot read disk file"
    end
    local text = file:read("*a")
    file:close()
    if text:find("%z") then
      return nil, "Binary file cannot be reviewed as text"
    end
  elseif not exists then
    return nil, "No current changes"
  end
  local args = { "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "-U3" }
  if exists or M.is_tracked(root, path) then
    vim.list_extend(args, { "HEAD", "--", path })
  else
    vim.list_extend(args, { "--no-index", "--", "/dev/null", full })
  end
  local result = git(root, args)
  if result.code > 1 then
    return nil, "Git comparison failed: " .. (result.stderr or "unknown error")
  end
  local raw = lines(result.stdout)
  for _, line in ipairs(raw) do
    if line:match("^@@") then
      break
    end
    if line:match("^Binary files .+ and .+ differ$") then
      return nil, "Binary file cannot be reviewed as text"
    end
  end
  local hunks, stats = parse_hunks(raw)
  if #hunks == 0 then
    return nil, "No current text changes"
  end
  return {
    rel_path = path,
    status = not exists and "added" or not disk and "deleted" or "modified",
    hunks = hunks,
    stats = stats,
    raw = raw,
  }
end
--- Compatibility diff API; unavailable comparisons have no entry.
---@param root string
---@param path string
---@return FileDiff|nil
function M.file_diff(root, path)
  local comparison = M.review(root, path)
  return comparison
end
--- Enumerate safe changed paths, including missing tracked and untracked files.
---@param root string
---@return string[]
---@return string|nil
function M.changed_files(root)
  if type(root) ~= "string" or not vim.uv.fs_realpath(root) then
    return {}, "Repository unavailable"
  end
  if not has_head(root) then
    return {}, "HEAD baseline unavailable"
  end
  local tracked = git(root, {
    "diff",
    "--relative",
    "--no-ext-diff",
    "--no-textconv",
    "--no-renames",
    "--name-only",
    "-z",
    "HEAD",
    "--",
  })
  local untracked = git(root, { "ls-files", "--others", "--exclude-standard", "-z", "--" })
  if tracked.code ~= 0 or untracked.code ~= 0 then
    return {}, "Cannot enumerate current changes"
  end
  local unique = {}
  for path in (tracked.stdout .. untracked.stdout):gmatch("([^%z]+)%z") do
    if paths.resolve(root, path, true) then
      unique[path] = true
    end
  end
  local result = {}
  for path in pairs(unique) do
    result[#result + 1] = path
  end
  table.sort(result)
  return result
end
--- Paths Git ignores, relative to root. Tracked files are never ignored.
---@param root string
---@param candidates string[]
---@return table<string, boolean>
function M.ignored(root, candidates)
  local ignored = {}
  if #candidates == 0 then
    return ignored
  end
  -- check-ignore reads literal paths from stdin and rejects pathspec magic flags.
  local result = git(root, { "check-ignore", "-z", "--stdin" }, {
    literal = false,
    stdin = table.concat(candidates, "\0") .. "\0",
  })
  if result.code == 0 then
    for path in result.stdout:gmatch("([^%z]+)%z") do
      ignored[path] = true
    end
  end
  return ignored
end
--- Ignored untracked directories under a root-relative directory ("" for all).
---@param root string
---@param directory string
---@return table<string, boolean>
function M.ignored_directories(root, directory)
  local args = { "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory" }
  vim.list_extend(args, { "--", directory ~= "" and directory or "." })
  local result = git(root, args)
  local ignored = {}
  if result.code == 0 then
    for path in result.stdout:gmatch("([^%z]+)%z") do
      if path:sub(-1) == "/" then
        ignored[path:sub(1, -2)] = true
      end
    end
  end
  return ignored
end
--- Current text comparison summaries.
---@param root string
---@return table[]
function M.status_summary(root)
  local result = {}
  for _, path in ipairs(M.changed_files(root)) do
    local fd = M.review(root, path)
    if fd then
      result[#result + 1] = {
        path = path,
        status = fd.status,
        insertions = fd.stats.added,
        deletions = fd.stats.removed,
      }
    end
  end
  return result
end
return M
