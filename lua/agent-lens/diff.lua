--- Git diff engine.
--- Computes diffs between working tree and HEAD using git.

local M = {}

--- Get the git root directory for a path.
---@param path? string Starting path (defaults to cwd)
---@return string|nil root Git root or nil if not in a repo
function M.git_root(path)
  local dir = path or vim.fn.getcwd()
  local result = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or #result == 0 then
    return nil
  end
  return result[1]
end

--- Check if a file is tracked by git.
---@param root string Git root
---@param rel_path string Relative path from root
---@return boolean
function M.is_tracked(root, rel_path)
  vim.fn.system({ "git", "-C", root, "ls-files", "--error-unmatch", rel_path })
  return vim.v.shell_error == 0
end

--- Get the HEAD version of a file.
---@param root string Git root
---@param rel_path string Relative path from root
---@return string[]|nil lines Lines of the HEAD version, nil if untracked
function M.head_contents(root, rel_path)
  local result = vim.fn.systemlist({ "git", "-C", root, "show", "HEAD:" .. rel_path })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result
end

--- Get the working tree version of a file.
---@param root string Git root
---@param rel_path string Relative path from root
---@return string[]|nil lines
function M.working_contents(root, rel_path)
  local full_path = root .. "/" .. rel_path
  local stat = (vim.uv or vim.loop).fs_stat(full_path)
  if not stat then
    return nil
  end
  local lines = {}
  for line in io.lines(full_path) do
    lines[#lines + 1] = line
  end
  return lines
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
    elseif current_hunk and (line:sub(1, 1) == "+" or line:sub(1, 1) == "-" or line:sub(1, 1) == " ") then
      current_hunk.lines[#current_hunk.lines + 1] = line
    end
  end

  if current_hunk then
    hunks[#hunks + 1] = current_hunk
  end

  return hunks
end

--- Compute the diff for a single file against HEAD.
---@param root string Git root
---@param rel_path string Relative path from root
---@return FileDiff|nil diff Nil if no changes
function M.file_diff(root, rel_path)
  local is_tracked = M.is_tracked(root, rel_path)

  local raw
  if is_tracked then
    raw = vim.fn.systemlist({ "git", "-C", root, "diff", "--no-color", "-U3", "HEAD", "--", rel_path })
  else
    -- Untracked file — diff against /dev/null
    raw = vim.fn.systemlist({ "git", "-C", root, "diff", "--no-color", "-U3", "--no-index", "/dev/null", rel_path })
  end

  if #raw == 0 then
    return nil
  end

  local hunks = parse_hunks(raw)
  if #hunks == 0 then
    return nil
  end

  local added, removed = 0, 0
  for _, hunk in ipairs(hunks) do
    for _, line in ipairs(hunk.lines) do
      if line:sub(1, 1) == "+" then
        added = added + 1
      elseif line:sub(1, 1) == "-" then
        removed = removed + 1
      end
    end
  end

  local status = "modified"
  if not is_tracked then
    status = "added"
  elseif removed > 0 and added == 0 then
    status = "deleted"
  end

  return {
    rel_path = rel_path,
    status = status,
    hunks = hunks,
    stats = { added = added, removed = removed },
    raw = raw,
  }
end

--- Get a summary of all changed files in the working tree.
---@param root string Git root
---@return table[] files List of {path, status, insertions, deletions}
function M.status_summary(root)
  local result = vim.fn.systemlist({ "git", "-C", root, "diff", "--stat", "--numstat", "HEAD" })
  if vim.v.shell_error ~= 0 then
    return {}
  end

  local files = {}
  for _, line in ipairs(result) do
    local ins, del, path = line:match("^(%d+)%s+(%d+)%s+(.+)$")
    if ins and del and path then
      files[#files + 1] = {
        path = path,
        insertions = tonumber(ins),
        deletions = tonumber(del),
      }
    end
  end
  return files
end

return M
