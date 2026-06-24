-- Assert a vX.Y.Z tag matches omelette/init.lua's version.
-- Required as a module by tests; runs the check when executed directly.
local M = {}

function M.check(tag, version)
  local stripped = tag and tag:match("^v(%d+%.%d+%.%d+)$")
  if not stripped then return false, "tag '" .. tostring(tag) .. "' is not of the form vX.Y.Z" end
  if stripped ~= version then
    return false, "tag " .. tag .. " does not match init.lua version " .. tostring(version)
  end
  return true, nil
end

function M.read_init_version(path)
  local fh = io.open(path or "omelette/init.lua", "r")
  if not fh then return nil end
  local src = fh:read("*a"); fh:close()
  return src:match('version%s*=%s*"([^"]+)"')
end

-- run directly: `luajit scripts/check-version.lua vX.Y.Z`
if arg and arg[0] and arg[0]:find("check%-version") then
  local version = M.read_init_version("omelette/init.lua")
  local ok, msg = M.check(arg[1], version)
  if not ok then io.stderr:write("version check failed: " .. tostring(msg) .. "\n"); os.exit(1) end
  io.write("version ok: " .. tostring(arg[1]) .. "\n")
  os.exit(0)
end

return M
