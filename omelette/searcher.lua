local compiler = require("omelette.compiler")
local M = {}

local roots = { "./?.egg", "./?/init.egg" }

local function read(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local d = fh:read("*a"); fh:close(); return d
end

local function loader(name)
  local rel = name:gsub("%.", "/")
  for _, pat in ipairs(roots) do
    local path = pat:gsub("%?", rel)
    local src = read(path)
    if src then
      local lua, err = compiler.compile(src)
      if not lua then return "\n\t[omelette] " .. (err and err.message or "compile error") end
      local chunk
      if _VERSION == "Lua 5.1" then chunk = assert(loadstring(lua, path))
      else chunk = assert(load(lua, path)) end
      return chunk
    end
  end
  return "\n\tno .egg file for '" .. name .. "'"
end

function M.install(extra_roots)
  if extra_roots then
    for _, r in ipairs(extra_roots) do table.insert(roots, 1, r) end
  end
  local searchers = package.searchers or package.loaders
  table.insert(searchers, loader)
end

return M
