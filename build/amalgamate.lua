-- Bundle omelette/*.lua into one self-contained `omelette` script via package.preload.
local M = {}

local MODULES = {
  "lexer", "errors", "resolver", "parser", "codegen",
  "compiler", "searcher", "repl", "cli", "init",
}

local function read(path)
  local fh = assert(io.open(path, "r"), "cannot read " .. path)
  local s = fh:read("*a"); fh:close()
  return s
end

function M.build()
  local parts = { "#!/usr/bin/env lua" }
  for _, name in ipairs(MODULES) do
    local mod = (name == "init") and "omelette" or ("omelette." .. name)
    parts[#parts + 1] = 'package.preload["' .. mod .. '"] = function(...)'
    parts[#parts + 1] = read("omelette/" .. name .. ".lua")
    parts[#parts + 1] = "end"
  end
  parts[#parts + 1] = 'return require("omelette.cli").main(arg)'
  return table.concat(parts, "\n")
end

-- run directly: `luajit build/amalgamate.lua > dist/omelette`
if arg and arg[0] and arg[0]:find("amalgamate") then
  io.write(M.build())
  os.exit(0)
end

return M
