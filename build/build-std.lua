-- Compile std/*.egg -> Lua at BUILD time. std/*.egg stays the sole committed source of
-- truth; nothing generated here is committed. Consumed by build/amalgamate.lua
-- (preload_block, inlined into the single-file binary) and the LuaRocks command build
-- (write_lua, emits installed std/*.lua). Reads std/ and requires omelette.compiler
-- relative to CWD, which is the repo root in every caller (amalgamate, the rock build,
-- the test suite).
local compiler = require("omelette.compiler")
local M = {}

M.STD = { "std.list", "std.string", "std.table" }

local function leaf(modname) return (modname:gsub("^std%.", "")) end

local function read(path)
  local fh = assert(io.open(path, "r"), "build-std: cannot read " .. path)
  local s = fh:read("*a"); fh:close()
  return s
end

function M.source(modname)
  return read("std/" .. leaf(modname) .. ".egg")
end

function M.compile(modname)
  local lua, err = compiler.compile(M.source(modname))
  if not lua then
    error("build-std: compiling " .. modname .. " failed: " .. (err and err.message or "?"))
  end
  return lua
end

function M.compile_all()
  local out = {}
  for _, name in ipairs(M.STD) do
    out[#out + 1] = { module = name, lua = M.compile(name) }
  end
  return out
end

function M.preload_block()
  local parts = {}
  for _, m in ipairs(M.compile_all()) do
    parts[#parts + 1] = 'package.preload["' .. m.module .. '"] = function(...)'
    parts[#parts + 1] = m.lua
    parts[#parts + 1] = "end"
  end
  return table.concat(parts, "\n")
end

function M.write_lua(outdir)
  os.execute('mkdir -p "' .. outdir .. '/std"')
  local written = {}
  for _, m in ipairs(M.compile_all()) do
    local path = outdir .. "/std/" .. leaf(m.module) .. ".lua"
    local fh = assert(io.open(path, "w"), "build-std: cannot write " .. path)
    fh:write(m.lua); fh:close()
    written[#written + 1] = path
  end
  return written
end

-- run directly: `lua build/build-std.lua <outdir>` — the LuaRocks build_command entry point.
-- Guarded on arg[0] so `dofile`/`require` from another script never triggers it.
if arg and arg[0] and arg[0]:find("build%-std") then
  local outdir = arg[1] or "build-out"
  for _, p in ipairs(M.write_lua(outdir)) do io.write(p .. "\n") end
  os.exit(0)
end

return M
