local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local M = {}

-- Syntax errors first, then type errors in the statements that parsed.
function M.check(source)
  local parsed = parser.parse_all(source)
  local typecheck = require("omelette.typecheck")
  local diags = parsed.diagnostics
  for _, d in ipairs(typecheck.check(parsed.program)) do diags[#diags + 1] = d end
  return diags, nil
end

function M.compile(source, opts)
  local program, perr = parser.parse(source)
  if not program then return nil, perr end
  if opts and opts.check then
    local typecheck = require("omelette.typecheck")
    local diags = typecheck.check(program)
    if #diags > 0 then return nil, diags[1] end
  end
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
