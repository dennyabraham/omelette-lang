local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local M = {}

function M.compile(source)
  local program, perr = parser.parse(source)
  if not program then return nil, perr end
  local resolver = require("omelette.resolver")
  program = resolver.resolve(program)
  local ok, lua = pcall(codegen.program, program)
  if not ok then
    local errors = require("omelette.errors")
    return nil, errors.new("codegen failed: " .. tostring(lua), 1, 1)
  end
  return lua, nil
end

function M.eval(source, name)
  local lua, err = M.compile(source)
  if not lua then return nil, err end
  -- load() works on both Lua 5.1 (loadstring) and 5.2+; prefer load if it takes a string
  local chunk, lerr
  if _VERSION == "Lua 5.1" then
    chunk, lerr = loadstring(lua, name or "omelette")
  else
    chunk, lerr = load(lua, name or "omelette")
  end
  if not chunk then
    local errors = require("omelette.errors")
    return nil, errors.new("generated lua failed to load: " .. tostring(lerr), 1, 1)
  end
  return chunk(), nil
end

return M
