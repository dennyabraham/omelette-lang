-- optional, erased static type checking (cycle 1): primitives + function types + any.
local errors = require("omelette.errors")
local M = {}

-- type reps
local ANY = { kind = "any" }
local NUMBER = { kind = "number" }
local STRING = { kind = "string" }
local BOOLEAN = { kind = "boolean" }
local NILT = { kind = "nil" }

-- convert a parse_type AST node (or false/nil for untyped) to a type rep
local function to_type(node)
  if not node then return ANY end
  if node.kind == "type_name" then
    local n = node.name
    if n == "number" then return NUMBER end
    if n == "string" then return STRING end
    if n == "boolean" then return BOOLEAN end
    if n == "nil" then return NILT end
    return ANY  -- "any" and any unknown / cycle-2 type name
  end
  if node.kind == "fun_type" then
    local params = {}
    for _, p in ipairs(node.params) do params[#params + 1] = to_type(p) end
    return { kind = "fun", params = params, ret = to_type(node.ret) }
  end
  return ANY
end

local function consistent(a, b)
  if a.kind == "any" or b.kind == "any" then return true end
  if a.kind == "fun" and b.kind == "fun" then
    if #a.params ~= #b.params then return false end
    for i = 1, #a.params do
      if not consistent(a.params[i], b.params[i]) then return false end
    end
    return consistent(a.ret, b.ret)
  end
  return a.kind == b.kind
end

local function tyname(t) return t.kind == "fun" and "function" or t.kind end

-- scoped environment
local function scope(parent) return { vars = {}, parent = parent } end
local function lookup(env, name)
  local e = env
  while e do
    if e.vars[name] ~= nil then return e.vars[name] end
    e = e.parent
  end
  return nil
end

local function collect_pattern_vars(pat, out)
  local k = pat.kind
  if k == "var" then out[#out + 1] = pat.name
  elseif k == "array_pat" then for _, p in ipairs(pat.elems) do collect_pattern_vars(p, out) end
  elseif k == "record_pat" then for _, f in ipairs(pat.fields) do collect_pattern_vars(f.pat, out) end
  elseif k == "ctor_pat" then for _, f in ipairs(pat.fields) do collect_pattern_vars(f.pat, out) end
  end
end

local Checker = {}
Checker.__index = Checker
local function new_checker() return setmetatable({ diags = {} }, Checker) end
function Checker:err(msg, node)
  self.diags[#self.diags + 1] = errors.new(msg, node.line or 1, node.col or 1)
end

-- the declared type of a top-level/local binding (for the environment)
function Checker:decl_type(node)
  if node.params then
    local params = {}
    for i = 1, #node.params do
      params[i] = to_type(node.param_types and node.param_types[i])
    end
    return { kind = "fun", params = params, ret = node.ret_type and to_type(node.ret_type) or ANY }
  end
  return node.value_type and to_type(node.value_type) or ANY
end

local ARITH = { ["+"]=true, ["-"]=true, ["*"]=true, ["/"]=true, ["%"]=true }
local CMP = { ["=="]=true, ["~="]=true, ["<"]=true, ["<="]=true, [">"]=true, [">="]=true }

-- build the variant registry from all top-level type declarations
function Checker:build_registry(program)
  self.types = {}
  self.ctor_owner = {}
  for _, node in ipairs(program.stmts) do
    if node.kind == "type_decl" then
      local entry = { ctors = {}, fields = {} }
      self.types[node.name] = entry
      for _, v in ipairs(node.variants) do
        if self.ctor_owner[v.name] then
          self:err("constructor '" .. v.name .. "' declared in both '"
            .. self.ctor_owner[v.name].type .. "' and '" .. node.name .. "'", node)
        end
        entry.ctors[#entry.ctors + 1] = v.name
        entry.fields[v.name] = v.fields
        local fieldset = {}
        for _, f in ipairs(v.fields) do fieldset[f] = true end
        self.ctor_owner[v.name] = { type = node.name, fields = v.fields, fieldset = fieldset }
      end
    end
  end
end

-- validate constructor patterns anywhere in a pattern tree (declared tag → fields must be a
-- subset of the declared fields). `at` is the enclosing match node (patterns carry no line/col).
function Checker:validate_pattern(pat, at)
  local k = pat.kind
  if k == "ctor_pat" then
    local owner = self.ctor_owner[pat.tag]
    if owner then
      for _, f in ipairs(pat.fields) do
        if not owner.fieldset[f.key] then
          self:err("unknown field '" .. f.key .. "' in pattern for constructor '" .. pat.tag
            .. "' (fields: " .. table.concat(owner.fields, ", ") .. ")", at)
        end
      end
    end
    for _, f in ipairs(pat.fields) do self:validate_pattern(f.pat, at) end
  elseif k == "array_pat" then
    for _, p in ipairs(pat.elems) do self:validate_pattern(p, at) end
  elseif k == "record_pat" then
    for _, f in ipairs(pat.fields) do self:validate_pattern(f.pat, at) end
  end
end

function Checker:synth(node, env)
  local k = node.kind
  if k == "number" then return NUMBER end
  if k == "string" then return STRING end
  if k == "bool" then return BOOLEAN end
  if k == "nil" then return NILT end
  if k == "ident" then return lookup(env, node.name) or ANY end
  if k == "lua_raw" or k == "hole" then return ANY end
  if k == "field" then self:synth(node.obj, env); return ANY end
  if k == "index" then self:synth(node.obj, env); self:synth(node.key, env); return ANY end
  if k == "binop" then
    local lt, rt = self:synth(node.lhs, env), self:synth(node.rhs, env)
    local op = node.op
    if ARITH[op] then
      if not consistent(lt, NUMBER) then self:err("arithmetic '" .. op .. "' expects number, got " .. tyname(lt), node.lhs) end
      if not consistent(rt, NUMBER) then self:err("arithmetic '" .. op .. "' expects number, got " .. tyname(rt), node.rhs) end
      return NUMBER
    elseif op == ".." then
      if not consistent(lt, STRING) then self:err("'..' expects string, got " .. tyname(lt), node.lhs) end
      if not consistent(rt, STRING) then self:err("'..' expects string, got " .. tyname(rt), node.rhs) end
      return STRING
    elseif CMP[op] then
      return BOOLEAN
    end
    return ANY  -- and / or
  end
  if k == "unop" then
    local t = self:synth(node.operand, env)
    if node.op == "-" then
      if not consistent(t, NUMBER) then self:err("unary '-' expects number, got " .. tyname(t), node.operand) end
      return NUMBER
    elseif node.op == "not" then return BOOLEAN end
    return NUMBER  -- '#'
  end
  if k == "call" then return self:synth_call(node.fn, node.args, node, env) end
  if k == "pipe" then
    local rhs = node.rhs
    if rhs.kind == "call" then
      local args = { node.lhs }
      for _, a in ipairs(rhs.args) do args[#args + 1] = a end
      return self:synth_call(rhs.fn, args, node, env)
    end
    return self:synth_call(rhs, { node.lhs }, node, env)
  end
  if k == "lambda" then
    local s = scope(env)
    local params = {}
    for _, p in ipairs(node.params) do s.vars[p] = ANY; params[#params + 1] = ANY end
    return { kind = "fun", params = params, ret = self:synth(node.body, s) }
  end
  if k == "if" then
    self:synth(node.cond, env)
    local a, b = self:synth(node.then_branch, env), self:synth(node.else_branch, env)
    if a.kind == b.kind and consistent(a, b) then return a end
    return ANY
  end
  if k == "match" then
    self:synth(node.subject, env)
    local ty
    for _, c in ipairs(node.cases) do
      self:validate_pattern(c.pattern, node)
      local s = scope(env)
      local names = {}
      collect_pattern_vars(c.pattern, names)
      for _, n in ipairs(names) do s.vars[n] = ANY end
      if c.guard then self:synth(c.guard, s) end
      local bt = self:synth(c.body, s)
      if ty == nil then ty = bt elseif ty.kind ~= bt.kind then ty = ANY end
    end
    return ty or ANY
  end
  if k == "block" then
    local s = scope(env)
    for _, st in ipairs(node.stmts) do self:check_binding(st, s) end
    return self:synth(node.result, s)
  end
  if k == "array" then for _, it in ipairs(node.items) do self:synth(it, env) end; return ANY end
  if k == "table" then for _, f in ipairs(node.fields) do self:synth(f.value, env) end; return ANY end
  if k == "construct" then
    for _, f in ipairs(node.fields) do self:synth(f.value, env) end
    local owner = self.ctor_owner and self.ctor_owner[node.tag]
    if owner then
      local provided = {}
      for _, f in ipairs(node.fields) do
        provided[f.key] = true
        if not owner.fieldset[f.key] then
          self:err("unknown field '" .. f.key .. "' for constructor '" .. node.tag
            .. "' (fields: " .. table.concat(owner.fields, ", ") .. ")", node)
        end
      end
      for _, fname in ipairs(owner.fields) do
        if not provided[fname] then
          self:err("missing field '" .. fname .. "' for constructor '" .. node.tag .. "'", node)
        end
      end
    end
    return ANY
  end
  -- comprehension / range / dict_comprehension: collection typing is cycle 2 -> any (not walked)
  return ANY
end

function Checker:synth_call(fnnode, args, callnode, env)
  local ft = self:synth(fnnode, env)
  local argtypes, has_hole = {}, false
  for _, a in ipairs(args) do
    if a.kind == "hole" then has_hole = true; argtypes[#argtypes + 1] = ANY
    else argtypes[#argtypes + 1] = self:synth(a, env) end
  end
  if ft.kind ~= "fun" or has_hole then return ft.kind == "fun" and ft.ret or ANY end
  if #argtypes ~= #ft.params then
    self:err("call expects " .. #ft.params .. " argument(s), got " .. #argtypes, callnode)
    return ft.ret
  end
  for i = 1, #argtypes do
    if not consistent(argtypes[i], ft.params[i]) then
      self:err("argument " .. i .. " expects " .. tyname(ft.params[i]) .. ", got " .. tyname(argtypes[i]), args[i])
    end
  end
  return ft.ret
end

-- check a `let` binding and add it to the scope
function Checker:check_binding(node, env)
  if node.params then
    env.vars[node.name] = self:decl_type(node)   -- declare first (recursion)
    local s = scope(env)
    for i = 1, #node.params do
      s.vars[node.params[i]] = to_type(node.param_types and node.param_types[i])
    end
    local mark = #self.diags
    local bodyt = self:synth(node.value, s)
    if node.ret_type then
      local rt = to_type(node.ret_type)
      if not consistent(bodyt, rt) then
        -- insert ahead of any diagnostics the body synth itself produced (e.g. an
        -- operand-type error inside the returned expression), so the return-type
        -- mismatch -- the more directly relevant diagnostic for this binding --
        -- is reported first.
        local msg = "function '" .. node.name .. "' returns " .. tyname(bodyt) .. ", declared " .. tyname(rt)
        table.insert(self.diags, mark + 1, errors.new(msg, node.line or 1, node.col or 1))
      end
    end
  else
    local vt = self:synth(node.value, env)
    if node.value_type then
      local dt = to_type(node.value_type)
      if not consistent(vt, dt) then
        self:err("'" .. node.name .. "' is declared " .. tyname(dt) .. " but assigned " .. tyname(vt), node)
      end
      env.vars[node.name] = dt
    else
      env.vars[node.name] = vt
    end
  end
end

function M.check(program)
  local c = new_checker()
  c:build_registry(program)
  local genv = scope(nil)
  -- pass 1: declare all top-level binding types (so calls resolve regardless of order)
  for _, node in ipairs(program.stmts) do
    if node.kind == "let" then genv.vars[node.name] = c:decl_type(node) end
  end
  -- pass 2: check bodies (check_binding re-declares, which is fine/idempotent)
  for _, node in ipairs(program.stmts) do
    if node.kind == "let" then c:check_binding(node, genv)
    elseif node.kind ~= "type_decl" then c:synth(node, genv) end
  end
  return c.diags
end

return M
