local M = {}

local cached_build_id = nil

function M.id()
  if cached_build_id ~= nil then
    return cached_build_id
  end

  local ok, contents = pcall(love.filesystem.read, "ble-build-id.txt")
  if not ok or type(contents) ~= "string" then
    cached_build_id = "?"
    return cached_build_id
  end

  contents = contents:gsub("%s+$", "")
  cached_build_id = contents ~= "" and contents or "?"
  return cached_build_id
end

return M
