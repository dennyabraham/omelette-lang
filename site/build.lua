-- Builds the Omelette website into site/dist/. `build_bundle()` produces the
-- browser compiler bundle (loaded into Fengari); `build()` (Task 2) assembles dist/.
local M = {}

-- compiler modules the browser needs (NB: typecheck is included — it is missing
-- from build/amalgamate.lua; the searcher/repl/cli are NOT needed in the browser)
local BUNDLE_MODULES = { "lexer", "errors", "resolver", "parser", "codegen", "typecheck", "compiler" }
local STD_MODULES = { "list", "string", "table" }

local function read(path)
  local fh = assert(io.open(path, "r"), "cannot read " .. path)
  local s = fh:read("*a"); fh:close(); return s
end

-- long-bracket level that does not collide with the source
local function longstring(s)
  local eq = "="
  while s:find("]" .. eq .. "]", 1, true) do eq = eq .. "=" end
  return "[" .. eq .. "[\n" .. s .. "]" .. eq .. "]"
end

function M.build_bundle()
  local parts = {}
  -- 1) preload every compiler module
  for _, name in ipairs(BUNDLE_MODULES) do
    parts[#parts + 1] = 'package.preload["omelette.' .. name .. '"] = function(...)'
    parts[#parts + 1] = read("omelette/" .. name .. ".lua")
    parts[#parts + 1] = "end"
  end
  -- 2) embed the stdlib sources
  parts[#parts + 1] = "local __omelette_std = {}"
  for _, name in ipairs(STD_MODULES) do
    parts[#parts + 1] = '__omelette_std["std.' .. name .. '"] = ' .. longstring(read("std/" .. name .. ".egg"))
  end
  -- 3) a browser searcher: compile embedded .egg sources on require (no filesystem)
  parts[#parts + 1] = [[
local __searchers = package.searchers or package.loaders
table.insert(__searchers, function(name)
  local src = __omelette_std[name]
  if not src then return "\n\tno embedded module '" .. name .. "'" end
  local lua, err = require("omelette.compiler").compile(src)
  if not lua then return "\n\t[omelette] " .. (err and err.message or "compile error") end
  local chunk, lerr = load(lua, name)
  if not chunk then return "\n\t[omelette] " .. tostring(lerr) end
  return chunk
end)
]]
  return table.concat(parts, "\n")
end

return M
