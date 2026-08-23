-- Bundle omelette/*.lua into one self-contained `omelette` script via package.preload.
local M = {}

local MODULES = {
  "lexer", "errors", "resolver", "parser", "codegen", "typecheck",
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
  -- os.exit with the CLI's status (a top-level `return` is ignored, so the
  -- single-file binary would otherwise always exit 0 — breaking `check` in scripts)
  parts[#parts + 1] = 'os.exit(require("omelette.cli").main(arg))'
  return table.concat(parts, "\n")
end

-- run directly: `luajit build/amalgamate.lua > dist/omelette`
if arg and arg[0] and arg[0]:find("amalgamate") then
  io.write(M.build())
  os.exit(0)
end

return M
