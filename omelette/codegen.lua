local M = {}

function M.new_ctx() return {} end

local function quote_string(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t") .. '"'
end

local BINOP_LUA = {
  ["=="]="==", ["~="]="~=", ["<"]="<", ["<="]="<=", [">"]=">", [">="]=">=",
  [".."]="..", ["+"]="+", ["-"]="-", ["*"]="*", ["/"]="/", ["%"]="%",
  ["and"]="and", ["or"]="or",
}

local expr  -- forward declaration
local gen_local_let, gen_fn_body  -- forward declarations for statement helpers

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
  local rhs = node.rhs
  if rhs.kind == "call" then
    -- build a new call AST node with the lhs node prepended to rhs args,
    -- then route through gen_call so hole-args are handled correctly
    local new_args = { node.lhs }
    for _, a in ipairs(rhs.args) do new_args[#new_args + 1] = a end
    return gen_call({ kind = "call", fn = rhs.fn, args = new_args }, ctx)
  end
  -- bare ident / field: call it with the single threaded arg
  return expr(rhs, ctx) .. "(" .. expr(node.lhs, ctx) .. ")"
end

-- a comprehension compiles to a self-contained IIFE so it is valid in any
-- expression position. Generators become `for _, name in ipairs(src) do`,
-- guards become `if cond then`, opened in qualifier order; the innermost body
-- appends the yield expression to a fresh accumulator table.
local function gen_comprehension(node, ctx)
  ctx.acc = (ctx.acc or 0) + 1
  local acc = "__acc" .. ctx.acc
  local lines = { "(function()", "  local " .. acc .. " = {}" }
  local pad = "  "
  for _, q in ipairs(node.quals) do
    if q.kind == "generator" then
      if q.value_name then
        lines[#lines + 1] = pad .. "for " .. q.name .. ", " .. q.value_name
          .. " in pairs(" .. expr(q.source, ctx) .. ") do"
      else
        lines[#lines + 1] = pad .. "for _, " .. q.name
          .. " in ipairs(" .. expr(q.source, ctx) .. ") do"
      end
    else
      lines[#lines + 1] = pad .. "if " .. expr(q.cond, ctx) .. " then"
    end
    pad = pad .. "  "
  end
  lines[#lines + 1] = pad .. acc .. "[#" .. acc .. " + 1] = " .. expr(node.yield, ctx)
  for _ = 1, #node.quals do
    pad = pad:sub(1, #pad - 2)
    lines[#lines + 1] = pad .. "end"
  end
  lines[#lines + 1] = "  return " .. acc
  lines[#lines + 1] = "end)()"
  return table.concat(lines, "\n")
end

-- a range literal [a to b] compiles to a self-contained IIFE building {a..b}
local function gen_range(node, ctx)
  ctx.acc = (ctx.acc or 0) + 1
  local acc = "__acc" .. ctx.acc
  return table.concat({
    "(function()",
    "  local " .. acc .. " = {}",
    "  for __i = " .. expr(node.from, ctx) .. ", " .. expr(node.to, ctx) .. " do",
    "    " .. acc .. "[#" .. acc .. " + 1] = __i",
    "  end",
    "  return " .. acc,
    "end)()",
  }, "\n")
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
    local op = node.op == "not" and "not " or node.op  -- "not " | "-" | "#"
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
    -- f.key is always a bare identifier string (guaranteed by the parser via
    -- expect("ident").value), so it is safe to concatenate directly rather than
    -- routing through expr.
    for _, f in ipairs(node.fields) do parts[#parts + 1] = f.key .. " = " .. expr(f.value, ctx) end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  if k == "lambda" then
    return "function(" .. table.concat(node.params, ", ") .. ")\n" .. gen_fn_body(node.body, ctx, "  ") .. "\nend"
  end
  if k == "comprehension" then return gen_comprehension(node, ctx) end
  if k == "range" then return gen_range(node, ctx) end
  if k == "index" then
    local obj_kind = node.obj.kind
    local obj_code = expr(node.obj, ctx)
    -- Lua 5.1 disallows indexing a bare constructor/string/function literal directly
    -- (`{..}[k]`, `"s"[k]`, `function()end[k]` are syntax errors), so wrap those in parens.
    -- Other object kinds need no wrapping: binop/unop already self-parenthesize; call/pipe/
    -- comprehension yield call results; field/ident/index are already valid index targets.
    -- (lambda is unreachable as an index object today since the parser can't put a bare `fn`
    -- in object position, but it is included so the guard is structurally complete.)
    if obj_kind == "array" or obj_kind == "table" or obj_kind == "string" or obj_kind == "lambda" then
      obj_code = "(" .. obj_code .. ")"
    end
    return obj_code .. "[" .. expr(node.key, ctx) .. "]"
  end
  error("codegen: cannot emit expression of kind '" .. tostring(k) .. "'")
end

M.expr = expr

local gen_value  -- forward

-- emit statements assigning the value of `node` into variable `target`
gen_value = function(target, node, ctx, pad)
  local k = node.kind
  if k == "if" then
    local lines = {}
    lines[#lines + 1] = pad .. "if " .. M.expr(node.cond, ctx) .. " then"
    lines[#lines + 1] = gen_value(target, node.then_branch, ctx, pad .. "  ")
    lines[#lines + 1] = pad .. "else"
    lines[#lines + 1] = gen_value(target, node.else_branch, ctx, pad .. "  ")
    lines[#lines + 1] = pad .. "end"
    return table.concat(lines, "\n")
  end
  if k == "match" then
    local subj = M.expr(node.subject, ctx)
    -- collect literal cases in order; find the wildcard case (if any)
    local lit_cases, wildcard_case = {}, nil
    for _, c in ipairs(node.cases) do
      if c.pattern.kind == "wildcard" then
        wildcard_case = c
      else
        lit_cases[#lit_cases + 1] = c
      end
    end
    local lines = {}
    for i, c in ipairs(lit_cases) do
      local lit = M.expr({ kind = c.pattern.lit_kind, value = c.pattern.value,
        name = c.pattern.value }, ctx)
      local kw = i == 1 and "if " or "elseif "
      lines[#lines + 1] = pad .. kw .. subj .. " == " .. lit .. " then"
      lines[#lines + 1] = gen_value(target, c.body, ctx, pad .. "  ")
    end
    if wildcard_case then
      lines[#lines + 1] = pad .. "else"
      lines[#lines + 1] = gen_value(target, wildcard_case.body, ctx, pad .. "  ")
    end
    lines[#lines + 1] = pad .. "end"
    return table.concat(lines, "\n")
  end
  if k == "block" then
    local lines = {}
    for _, s in ipairs(node.stmts) do
      lines[#lines + 1] = gen_local_let(s, ctx, pad)
    end
    lines[#lines + 1] = gen_value(target, node.result, ctx, pad)
    return table.concat(lines, "\n")
  end
  -- simple expression
  return pad .. target .. " = " .. M.expr(node, ctx)
end

-- a `let` used as a local statement (inside a block or at file scope, non-pub)
gen_local_let = function(node, ctx, pad)
  pad = pad or ""
  if node.params then
    local body = gen_fn_body(node.value, ctx, pad .. "  ")
    return pad .. "local function " .. node.name .. "(" .. table.concat(node.params, ", ") .. ")\n"
      .. body .. "\n" .. pad .. "end"
  end
  -- value binding: declare then assign (handles if/match/block uniformly)
  if node.value.kind == "if" or node.value.kind == "match" or node.value.kind == "block" then
    return pad .. "local " .. node.name .. "\n" .. gen_value(node.name, node.value, ctx, pad)
  end
  return pad .. "local " .. node.name .. " = " .. M.expr(node.value, ctx)
end

-- function body returning the value of `node`
gen_fn_body = function(node, ctx, pad)
  local k = node.kind
  if k == "block" then
    -- emit inner lets as locals, then return the result
    local lines = {}
    for _, s in ipairs(node.stmts) do
      lines[#lines + 1] = gen_local_let(s, ctx, pad)
    end
    -- recurse so the result itself may be if/match/block
    lines[#lines + 1] = gen_fn_body(node.result, ctx, pad)
    return table.concat(lines, "\n")
  end
  if k == "if" or k == "match" then
    -- use a temporary return variable for clarity and falsy-safety
    return pad .. "local __ret\n" .. gen_value("__ret", node, ctx, pad) .. "\n" .. pad .. "return __ret"
  end
  return pad .. "return " .. M.expr(node, ctx)
end

function M.program(program)
  local ctx = M.new_ctx()
  local lines = { "local M = {}" }
  for _, node in ipairs(program.stmts) do
    if node.kind ~= "let" then
      -- bare top-level expression (side effect)
      lines[#lines + 1] = M.expr(node, ctx)
    elseif node.is_pub and node.params then
      lines[#lines + 1] = "function M." .. node.name .. "(" .. table.concat(node.params, ", ") .. ")"
      lines[#lines + 1] = gen_fn_body(node.value, ctx, "  ")
      lines[#lines + 1] = "end"
    elseif node.is_pub then
      if node.value.kind == "if" or node.value.kind == "match" or node.value.kind == "block" then
        lines[#lines + 1] = "local __" .. node.name
        lines[#lines + 1] = gen_value("__" .. node.name, node.value, ctx, "")
        lines[#lines + 1] = "M." .. node.name .. " = __" .. node.name
      else
        lines[#lines + 1] = "M." .. node.name .. " = " .. M.expr(node.value, ctx)
      end
    else
      lines[#lines + 1] = gen_local_let(node, ctx, "")
    end
  end
  lines[#lines + 1] = "return M"
  return table.concat(lines, "\n")
end

return M
