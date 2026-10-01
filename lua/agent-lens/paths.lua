local M = {}
local uv = vim.uv

local function relative_path(path)
  if
    type(path) ~= "string"
    or path == ""
    or path:find("[%z\1-\31]")
    or path:sub(1, 1) == "/"
    or path:find("//", 1, true)
    or path:sub(-1) == "/"
  then
    return false
  end
  for part in path:gmatch("[^/]+") do
    if part == "." or part == ".." then
      return false
    end
  end
  return path ~= ".git" and path:sub(1, 5) ~= ".git/"
end

local function inside(root, path)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end
local function has_symlink_component(root, candidate)
  local relative = candidate:sub(#root + 2)
  local component = root
  for part in relative:gmatch("[^/]+") do
    component = component .. "/" .. part
    local stat = uv.fs_lstat(component)
    if stat and stat.type == "link" then
      return true
    end
    if not stat then
      return false
    end
  end
  return false
end
--- Resolve and validate a workspace-relative file target.
---@param root string Workspace root path
---@param rel_path string Relative file path
---@param allow_missing? boolean Whether to allow non-existent leaf targets
---@return string|nil resolved Absolute path or nil if invalid/unsafe
function M.resolve(root, rel_path, allow_missing)
  if
    type(root) ~= "string"
    or root == ""
    or (allow_missing ~= nil and type(allow_missing) ~= "boolean")
    or not relative_path(rel_path)
  then
    return nil
  end
  local real_root = uv.fs_realpath(root)
  root = real_root or root
  local candidate = root .. "/" .. rel_path
  if not real_root or has_symlink_component(root, candidate) then
    return nil
  end
  local resolved = uv.fs_realpath(candidate)
  if resolved then
    local stat = uv.fs_stat(resolved)
    return stat and stat.type == "file" and inside(real_root, resolved) and resolved or nil
  end
  if not allow_missing or uv.fs_lstat(candidate) then
    return nil
  end

  local ancestor = candidate
  while true do
    local real_ancestor = uv.fs_realpath(ancestor)
    if real_ancestor then
      local stat = uv.fs_stat(real_ancestor)
      return stat and stat.type == "directory" and inside(real_root, real_ancestor) and candidate
        or nil
    end
    local parent = vim.fn.fnamemodify(ancestor, ":h")
    if parent == ancestor then
      return nil
    end
    ancestor = parent
  end
end

return M
