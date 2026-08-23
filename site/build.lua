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

local function write(path, data)
  local fh = assert(io.open(path, "w"), "cannot write " .. path)
  fh:write(data); fh:close()
end

local function copy(from, to) write(to, read(from)) end

function M.build()
  os.execute("mkdir -p site/dist")
  write("site/dist/omelette-browser.lua", M.build_bundle())
  copy("docs/guide.md", "site/dist/guide.md")
  for _, f in ipairs({ "index.html", "guide.html", "play.html", "site.css", "play.js" }) do
    copy("site/src/" .. f, "site/dist/" .. f)
  end
  -- vendored css + fonts
  for _, f in ipairs({ "fengari-web.js", "marked.min.js", "tufte.css" }) do
    copy("site/vendor/" .. f, "site/dist/" .. f)
  end
  -- et-book fonts (recursive copy via shell; portable enough for the build)
  os.execute("mkdir -p site/dist/et-book && cp -R site/vendor/et-book/. site/dist/et-book/")
end

-- run directly: `lua site/build.lua [--serve]`
if arg and arg[0] and arg[0]:find("build") and not package.loaded["spec.support.harness"] then
  M.build()
  io.write("built site/dist/\n")
  if arg[1] == "--serve" then
    io.write("serving http://localhost:8000  (Ctrl-C to stop)\n")
    os.execute("cd site/dist && python3 -m http.server 8000")
  end
end

return M
