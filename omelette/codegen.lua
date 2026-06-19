local M = {}

function M.new_ctx() return { holes = 0 } end

local function quote_string(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t") .. '"'
end

local BINOP_LUA = {
  ["=="]="==", ["~="]="~=", ["<"]="<", ["<="]="<=", [">"]=">", [">="]=">=",
  [".."]="..", ["+"]="+", ["-"]="-", ["*"]="*", ["/"]="/", ["%"]="%",
  ["and"]="and", ["or"]="or",
}

local expr  -- forward declaration

local function gen_args(args, ctx)
  local parts = {}
  for _, a in ipairs(args) do parts[#parts + 1] = expr(a, ctx) end
  return table.concat(parts, ", ")
end

-- a call whose args contain holes becomes a wrapping closure
local function gen_call(node, ctx)
  local has_hole = false
  for _, a in ipairs(node.args) do if a.kind == "hole" then has_hole = true break end end
  if not has_hole then
    return expr(node.fn, ctx) .. "(" .. gen_args(node.args, ctx) .. ")"
  end
  local params, filled, idx = {}, {}, 0
  for _, a in ipairs(node.args) do
    if a.kind == "hole" then
      idx = idx + 1
      local name = "__p" .. idx
      params[#params + 1] = name
      filled[#filled + 1] = name
    else
      filled[#filled + 1] = expr(a, ctx)
    end
  end
  return "(function(" .. table.concat(params, ", ") .. ") return "
    .. expr(node.fn, ctx) .. "(" .. table.concat(filled, ", ") .. ") end)"
end

-- pipe: thread lhs as the first argument of rhs
local function gen_pipe(node, ctx)
  local lhs_str = expr(node.lhs, ctx)
  local rhs = node.rhs
  if rhs.kind == "call" then
    -- build arg list: lhs_str first, then remaining rhs args
    local parts = { lhs_str }
    for _, a in ipairs(rhs.args) do parts[#parts + 1] = expr(a, ctx) end
    return expr(rhs.fn, ctx) .. "(" .. table.concat(parts, ", ") .. ")"
  end
  -- bare ident / field: call it with the single threaded arg
  return expr(rhs, ctx) .. "(" .. lhs_str .. ")"
end

expr = function(node, ctx)
  local k = node.kind
  if k == "number" then return tostring(node.value) end
  if k == "string" then return quote_string(node.value) end
  if k == "bool" then return tostring(node.value) end
  if k == "nil" then return "nil" end
  if k == "ident" then return node.name end
  if k == "lua_raw" then return node.code end
  if k == "field" then return expr(node.obj, ctx) .. "." .. node.name end
  if k == "binop" then
    return "(" .. expr(node.lhs, ctx) .. " " .. BINOP_LUA[node.op] .. " " .. expr(node.rhs, ctx) .. ")"
  end
  if k == "unop" then
    local op = node.op == "not" and "not " or "-"
    return "(" .. op .. expr(node.operand, ctx) .. ")"
  end
  if k == "call" then return gen_call(node, ctx) end
  if k == "pipe" then return gen_pipe(node, ctx) end
  if k == "array" then
    local parts = {}
    for _, it in ipairs(node.items) do parts[#parts + 1] = expr(it, ctx) end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  if k == "table" then
    local parts = {}
    for _, f in ipairs(node.fields) do parts[#parts + 1] = f.key .. " = " .. expr(f.value, ctx) end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  if k == "lambda" then
    return "function(" .. table.concat(node.params, ", ") .. ") return " .. expr(node.body, ctx) .. " end"
  end
  error("codegen: cannot emit expression of kind '" .. tostring(k) .. "'")
end

M.expr = expr
return M
