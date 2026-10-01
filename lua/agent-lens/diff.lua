--- Safe current HEAD-to-disk comparisons.
local M = {}
local paths = require("agent-lens.paths")
local function git(root, args)
  local command = { "git", "--literal-pathspecs", "-C", root }
  vim.list_extend(command, args)
  return vim.system(command, { text = false }):wait()
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
  local result = git(root, { "show", "HEAD:" .. path })
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

--- Parse a unified diff into structured hunks.
---@param diff_lines string[] Raw diff output lines
---@return DiffHunk[]
local function parse_hunks(diff_lines)
  local hunks = {}
  local current_hunk = nil

  for _, line in ipairs(diff_lines) do
    local old_s, old_c, new_s, new_c = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_s then
      if current_hunk then
        hunks[#hunks + 1] = current_hunk
      end
      current_hunk = {
        old_start = tonumber(old_s),
        old_count = tonumber(old_c) or 1,
        new_start = tonumber(new_s),
        new_count = tonumber(new_c) or 1,
        header = line,
        lines = {},
      }
    elseif
      current_hunk and (line:sub(1, 1) == "+" or line:sub(1, 1) == "-" or line:sub(1, 1) == " ")
    then
      current_hunk.lines[#current_hunk.lines + 1] = line
    end
  end

  if current_hunk then
    hunks[#hunks + 1] = current_hunk
  end

  return hunks
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
  local head = git(root, { "show", "HEAD:" .. path })
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
  if result.stdout:find("Binary files", 1, true) then
    return nil, "Binary file cannot be reviewed as text"
  end
  local hunks = parse_hunks(raw)
  if #hunks == 0 then
    return nil, "No current text changes"
  end
  local added, removed = 0, 0
  for _, h in ipairs(hunks) do
    for _, line in ipairs(h.lines) do
      if line:sub(1, 1) == "+" then
        added = added + 1
      elseif line:sub(1, 1) == "-" then
        removed = removed + 1
      end
    end
  end
  return {
    rel_path = path,
    status = not exists and "added" or not disk and "deleted" or "modified",
    hunks = hunks,
    stats = { added = added, removed = removed },
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
  local tracked = git(
    root,
    { "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z", "HEAD", "--" }
  )
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
