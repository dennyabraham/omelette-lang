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

-- A literal that can't be a Lua "prefix expression" (the base of an index/field/call)
-- without parens: `{..}[k]`, `{..}.f`, `"s".f`, `(fn..)(x)` are all syntax errors in
-- Lua 5.1. Wrap those bases in parens; everything else (ident/field/index/call results,
-- self-parenthesizing binops/unops) is already a valid prefix.
local PREFIX_NEEDS_PAREN = { array = true, table = true, string = true, lambda = true, construct = true }
local function prefix(node, ctx)
  local code = expr(node, ctx)
  if PREFIX_NEEDS_PAREN[node.kind] then return "(" .. code .. ")" end
  return code
end

local function gen_args(args, ctx)
  local parts = {}
  for _, a in ipairs(args) do parts[#parts + 1] = expr(a, ctx) end
  return table.concat(parts, ", ")
end

-- a call whose args contain holes becomes a wrapping closure
local function gen_call(node, ctx)
  if node.fn.kind == "construct" then
    -- `Some(x)` (reflexive ML call syntax) — constructors use named-field braces
    error("constructor '" .. node.fn.tag .. "' is built with braces, not call syntax: "
      .. "write " .. node.fn.tag .. " { field = ... }, not " .. node.fn.tag .. "(...)")
  end
  local has_hole = false
  for _, a in ipairs(node.args) do if a.kind == "hole" then has_hole = true break end end
  if not has_hole then
    return prefix(node.fn, ctx) .. "(" .. gen_args(node.args, ctx) .. ")"
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
    .. prefix(node.fn, ctx) .. "(" .. table.concat(filled, ", ") .. ") end)"
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

-- shared comprehension IIFE: opens the qualifier loops/guards in order, calls
-- `inner(acc)` for the innermost body line, then closes and returns the accumulator.
local function gen_comp_iife(node, ctx, inner)
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
  lines[#lines + 1] = pad .. inner(acc)
  for _ = 1, #node.quals do
    pad = pad:sub(1, #pad - 2)
    lines[#lines + 1] = pad .. "end"
  end
  lines[#lines + 1] = "  return " .. acc
  lines[#lines + 1] = "end)()"
  return table.concat(lines, "\n")
end

local function gen_comprehension(node, ctx)
  return gen_comp_iife(node, ctx, function(acc)
    return acc .. "[#" .. acc .. " + 1] = " .. expr(node.yield, ctx)
  end)
end

local function gen_dict_comprehension(node, ctx)
  return gen_comp_iife(node, ctx, function(acc)
    return acc .. "[" .. expr(node.key, ctx) .. "] = " .. expr(node.value, ctx)
  end)
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

-- walk a pattern against an access expression, appending Lua boolean test strings
-- to `tests` and `"local <name> = <access>"` binding strings to `binds`.
local function compile_pattern(pat, access, ctx, tests, binds)
  local k = pat.kind
  if k == "wildcard" then
    -- always matches, binds nothing
  elseif k == "var" then
    binds[#binds + 1] = "local " .. pat.name .. " = " .. access
  elseif k == "lit" then
    tests[#tests + 1] = access .. " == " .. expr({ kind = pat.lit_kind, value = pat.value }, ctx)
  elseif k == "array_pat" then
    tests[#tests + 1] = "type(" .. access .. ') == "table"'
    tests[#tests + 1] = "#" .. access .. " == " .. #pat.elems
    for i, sub in ipairs(pat.elems) do
      compile_pattern(sub, access .. "[" .. i .. "]", ctx, tests, binds)
    end
  elseif k == "record_pat" then
    tests[#tests + 1] = "type(" .. access .. ') == "table"'
    for _, f in ipairs(pat.fields) do
      compile_pattern(f.pat, access .. "." .. f.key, ctx, tests, binds)
    end
  elseif k == "ctor_pat" then
    tests[#tests + 1] = "type(" .. access .. ') == "table"'
    tests[#tests + 1] = access .. ".__tag == " .. quote_string(pat.tag)
    for _, f in ipairs(pat.fields) do
      compile_pattern(f.pat, access .. "." .. f.key, ctx, tests, binds)
    end
  end
end

-- an if used as a value sub-expression compiles to a self-contained IIFE that
-- returns from each branch (falsy-safe). if in binding/branch/return position keeps
-- its non-closure lowering in gen_value/gen_fn_body — this path is only reached when
-- an if appears in a genuine expression position (via M.expr).
local function gen_if(node, ctx)
  return table.concat({
    "(function()",
    "  if " .. expr(node.cond, ctx) .. " then",
    gen_fn_body(node.then_branch, ctx, "    "),
    "  else",
    gen_fn_body(node.else_branch, ctx, "    "),
    "  end",
    "end)()",
  }, "\n")
end

-- a match compiles to a self-contained IIFE: the subject is bound once; each case
-- opens `if <tests> then <binds> [if <guard> then] return <body> end`; on no match,
-- errors. Tests are `and`-joined and short-circuit, so structural tests (type/#)
-- always precede the deeper accesses they guard.
local function gen_match(node, ctx)
  ctx.acc = (ctx.acc or 0) + 1
  local subj = "__m" .. ctx.acc
  local lines = { "(function()", "  local " .. subj .. " = " .. expr(node.subject, ctx) }
  for _, c in ipairs(node.cases) do
    local tests, binds = {}, {}
    compile_pattern(c.pattern, subj, ctx, tests, binds)
    local cond = #tests > 0 and table.concat(tests, " and ") or "true"
    lines[#lines + 1] = "  if " .. cond .. " then"
    for _, b in ipairs(binds) do lines[#lines + 1] = "    " .. b end
    if c.guard then
      lines[#lines + 1] = "    if " .. expr(c.guard, ctx) .. " then"
      lines[#lines + 1] = gen_fn_body(c.body, ctx, "      ")
      lines[#lines + 1] = "    end"
    else
      lines[#lines + 1] = gen_fn_body(c.body, ctx, "    ")
    end
    lines[#lines + 1] = "  end"
  end
  lines[#lines + 1] = '  error("match: no matching case")'
  lines[#lines + 1] = "end)()"
  return table.concat(lines, "\n")
end

expr = function(node, ctx)
  local k = node.kind
  if k == "number" then return tostring(node.value) end
  if k == "string" then return quote_string(node.value) end
  if k == "bool" then return tostring(node.value) end
  if k == "nil" then return "nil" end
  if k == "ident" then return node.name end
  if k == "lua_raw" then return node.code end
  if k == "field" then return prefix(node.obj, ctx) .. "." .. node.name end
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
  if k == "dict_comprehension" then return gen_dict_comprehension(node, ctx) end
  if k == "range" then return gen_range(node, ctx) end
  if k == "index" then
    return prefix(node.obj, ctx) .. "[" .. expr(node.key, ctx) .. "]"
  end
  if k == "construct" then
    local parts = { "__tag = " .. quote_string(node.tag) }
    for _, f in ipairs(node.fields) do
      if f.key == "__tag" then
        error("field name '__tag' is reserved (it holds the constructor discriminant)")
      end
      parts[#parts + 1] = f.key .. " = " .. expr(f.value, ctx)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  if k == "if" then return gen_if(node, ctx) end
  if k == "match" then return gen_match(node, ctx) end
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
  if k == "if" then
    -- use a temporary return variable for clarity and falsy-safety
    return pad .. "local __ret\n" .. gen_value("__ret", node, ctx, pad) .. "\n" .. pad .. "return __ret"
  end
  return pad .. "return " .. M.expr(node, ctx)
end

-- like gen_local_let but assigns to an already-declared (forward-declared) local.
-- Used only at module top level, where all binding names are declared up front,
-- so top-level functions can reference each other in any order.
local function gen_top_assign(node, ctx)
  if node.params then
    local body = gen_fn_body(node.value, ctx, "  ")
    return "function " .. node.name .. "(" .. table.concat(node.params, ", ") .. ")\n"
      .. body .. "\nend"
  end
  if node.value.kind == "if" or node.value.kind == "match" or node.value.kind == "block" then
    return gen_value(node.name, node.value, ctx, "")
  end
  return node.name .. " = " .. M.expr(node.value, ctx)
end

function M.program(program)
  local ctx = M.new_ctx()
  local lines = { "local M = {}" }
  -- forward-declare all top-level let names so top-level functions can reference
  -- each other (and recurse) regardless of definition order
  local names = {}
  for _, node in ipairs(program.stmts) do
    if node.kind == "let" then names[#names + 1] = node.name end
  end
  if #names > 0 then
    lines[#lines + 1] = "local " .. table.concat(names, ", ")
  end
  for _, node in ipairs(program.stmts) do
    if node.kind == "type_decl" then
      -- erased: a type declaration emits no runtime code
    elseif node.kind ~= "let" then
      -- bare top-level expression (side effect)
      lines[#lines + 1] = M.expr(node, ctx)
    else
      lines[#lines + 1] = gen_top_assign(node, ctx)
      if node.is_pub then
        lines[#lines + 1] = "M." .. node.name .. " = " .. node.name
      end
    end
  end
  lines[#lines + 1] = "return M"
  return table.concat(lines, "\n")
end

return M
