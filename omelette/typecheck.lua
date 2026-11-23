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

-- A type as source text: `number`, `(number, string) -> boolean`.
function M.format_type(t)
  if t.kind ~= "fun" then return t.kind end
  local params = {}
  for i, p in ipairs(t.params) do params[i] = M.format_type(p) end
  return "(" .. table.concat(params, ", ") .. ") -> " .. M.format_type(t.ret)
end
local tyname = M.format_type

-- scoped environment
-- Each scope maps a name to its type (vars) and to the declaration that binds it (decls).
local function scope(parent) return { vars = {}, decls = {}, parent = parent } end
local function lookup_in(env, map, name)
  local e = env
  while e do
    if e[map][name] ~= nil then return e[map][name] end
    e = e.parent
  end
  return nil
end
local function lookup(env, name) return lookup_in(env, "vars", name) end
local function lookup_decl(env, name) return lookup_in(env, "decls", name) end

-- collects the pattern's `var` nodes
local function collect_pattern_vars(pat, out)
  local k = pat.kind
  if k == "var" then out[#out + 1] = pat
  elseif k == "array_pat" then for _, p in ipairs(pat.elems) do collect_pattern_vars(p, out) end
  elseif k == "record_pat" then for _, f in ipairs(pat.fields) do collect_pattern_vars(f.pat, out) end
  elseif k == "ctor_pat" then
    if pat.positional then for _, p in ipairs(pat.args) do collect_pattern_vars(p, out) end
    else for _, f in ipairs(pat.fields) do collect_pattern_vars(f.pat, out) end end
  end
end

local Checker = {}
Checker.__index = Checker
local function new_checker()
  return setmetatable({ diags = {}, binding_of = {}, type_of = {}, decl_at = {} }, Checker)
end
function Checker:err(msg, node)
  self.diags[#self.diags + 1] = errors.new(msg, node.line or 1, node.col or 1, nil, node.end_line, node.end_col)
end

-- The declaration record for a name declared by `at` (a token, or a pattern `var` node),
-- made once per `at` so that every pass that declares the name shares it.
function Checker:decl(name, kind, at, node)
  local d = self.decl_at[at]
  if not d then
    d = { name = name, kind = kind, line = at.start_line or at.line, col = at.start_col or at.col,
          end_line = at.end_line, end_col = at.end_col, node = node, type = ANY }
    self.decl_at[at] = d
    self.binding_of[at] = d   -- a declared name binds to its own declaration
  end
  return d
end

function Checker:declare(env, name, ty, decl)
  env.vars[name] = ty
  if decl then env.decls[name] = decl; decl.type = ty end
end

function Checker:let_decl(node)
  return node.name_tok and self:decl(node.name, node.params and "function" or "variable", node.name_tok, node)
end

-- declares each variable a pattern binds, as `any`
function Checker:declare_pattern(pat, env)
  local vars = {}; collect_pattern_vars(pat, vars)
  for _, v in ipairs(vars) do self:declare(env, v.name, ANY, self:decl(v.name, "variable", v, v)) end
end

-- binds the user-declared type names in an annotation
function Checker:bind_annotation(t)
  if not t then return end
  if t.kind == "type_name" and self.type_decls[t.name] then
    self.binding_of[t] = self.type_decls[t.name]
  elseif t.kind == "fun_type" then
    for _, p in ipairs(t.params) do self:bind_annotation(p) end
    self:bind_annotation(t.ret)
  end
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
  self.type_decls = {}
  for _, node in ipairs(program.stmts) do
    if node.kind == "type_decl" then
      local entry = { ctors = {}, fields = {} }
      self.types[node.name] = entry
      self.type_decls[node.name] = self:decl(node.name, "type", node.name_tok, node)
      for _, v in ipairs(node.variants) do
        if self.ctor_owner[v.name] then
          local prev = self.ctor_owner[v.name].type
          if prev == node.name then
            self:err("constructor '" .. v.name .. "' declared twice in '" .. node.name .. "'", node)
          else
            self:err("constructor '" .. v.name .. "' declared in both '"
              .. prev .. "' and '" .. node.name .. "'", node)
          end
        end
        entry.ctors[#entry.ctors + 1] = v.name
        if v.positional then
          self.ctor_owner[v.name] = { type = node.name, positional = true, arity = v.arity }
        else
          entry.fields[v.name] = v.fields
          local fieldset = {}
          for _, f in ipairs(v.fields) do fieldset[f] = true end
          self.ctor_owner[v.name] = { type = node.name, fields = v.fields, fieldset = fieldset }
        end
        self.ctor_owner[v.name].decl = self:decl(v.name, "enumMember", v.name_tok, node)
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
    if owner then self.binding_of[pat] = owner.decl end
    if pat.positional then
      if owner then
        if not owner.positional then
          self:err("constructor '" .. pat.tag .. "' takes named fields, not positional arguments", at)
        elseif #pat.args ~= owner.arity then
          self:err("constructor '" .. pat.tag .. "' expects " .. owner.arity
            .. " argument" .. (owner.arity == 1 and "" or "s") .. ", got " .. #pat.args, at)
        end
      end
      for _, p in ipairs(pat.args) do self:validate_pattern(p, at) end
    else
      if owner then
        if owner.positional then
          self:err("constructor '" .. pat.tag .. "' takes positional arguments, not named fields", at)
        else
          for _, f in ipairs(pat.fields) do
            if not owner.fieldset[f.key] then
              self:err("unknown field '" .. f.key .. "' in pattern for constructor '" .. pat.tag
                .. "' (fields: " .. table.concat(owner.fields, ", ") .. ")", at)
            end
          end
        end
      end
      for _, f in ipairs(pat.fields) do self:validate_pattern(f.pat, at) end
    end
  elseif k == "array_pat" then
    for _, p in ipairs(pat.elems) do self:validate_pattern(p, at) end
  elseif k == "record_pat" then
    for _, f in ipairs(pat.fields) do self:validate_pattern(f.pat, at) end
  end
end

-- match exhaustiveness: only over declared variants; guarded arms count as covered;
-- an unguarded top-level var/wildcard arm is a catch-all.
function Checker:check_exhaustive(node)
  local tags, seen, has_catchall = {}, {}, false
  for _, c in ipairs(node.cases) do
    local pk = c.pattern.kind
    if (pk == "var" or pk == "wildcard") and not c.guard then
      has_catchall = true
    elseif pk == "ctor_pat" then
      if not seen[c.pattern.tag] then seen[c.pattern.tag] = true; tags[#tags + 1] = c.pattern.tag end
    end
  end
  if #tags == 0 or has_catchall then return end   -- non-variant match, or covered
  local owner_type
  for _, tag in ipairs(tags) do
    local owner = self.ctor_owner[tag]
    if not owner then return end                  -- undeclared → lenient
    if owner_type == nil then
      owner_type = owner.type
    elseif owner_type ~= owner.type then
      self:err("match mixes constructors of different types ('" .. owner_type
        .. "' and '" .. owner.type .. "')", node)
      return
    end
  end
  local missing = {}
  for _, ctor in ipairs(self.types[owner_type].ctors) do
    if not seen[ctor] then missing[#missing + 1] = ctor end
  end
  if #missing > 0 then
    self:err("non-exhaustive match on '" .. owner_type .. "': missing "
      .. table.concat(missing, ", "), node)
  end
end

function Checker:synth(node, env)
  local t = self:synth_node(node, env)
  self.type_of[node] = t
  return t
end

function Checker:synth_node(node, env)
  local k = node.kind
  if k == "number" then return NUMBER end
  if k == "string" then return STRING end
  if k == "bool" then return BOOLEAN end
  if k == "nil" then return NILT end
  if k == "ident" then
    local d = lookup_decl(env, node.name)
    if d then self.binding_of[node] = d end
    return lookup(env, node.name) or ANY
  end
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
    for i, p in ipairs(node.params) do
      local tok = node.param_toks and node.param_toks[i]
      self:declare(s, p, ANY, tok and self:decl(p, "parameter", tok, node))
      params[#params + 1] = ANY
    end
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
      self:declare_pattern(c.pattern, s)
      if c.guard then self:synth(c.guard, s) end
      local bt = self:synth(c.body, s)
      if ty == nil then ty = bt elseif ty.kind ~= bt.kind then ty = ANY end
    end
    self:check_exhaustive(node)
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
    local bound = self.ctor_owner and self.ctor_owner[node.tag]
    if bound then self.binding_of[node] = bound.decl end
    if node.positional then
      for _, a in ipairs(node.args) do self:synth(a, env) end
      local owner = self.ctor_owner and self.ctor_owner[node.tag]
      if owner then
        if not owner.positional then
          self:err("constructor '" .. node.tag .. "' takes named fields, not positional arguments", node)
        elseif #node.args ~= owner.arity then
          self:err("constructor '" .. node.tag .. "' expects " .. owner.arity
            .. " argument" .. (owner.arity == 1 and "" or "s") .. ", got " .. #node.args, node)
        end
      end
      return ANY
    end
    for _, f in ipairs(node.fields) do self:synth(f.value, env) end
    local owner = self.ctor_owner and self.ctor_owner[node.tag]
    if owner then
      if owner.positional then
        self:err("constructor '" .. node.tag .. "' takes positional arguments, not named fields", node)
      else
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
    end
    return ANY
  end
  if k == "comprehension" or k == "dict_comprehension" then
    -- collection typing is cycle 2: generator variables are `any`, and the result is `any`
    local s = scope(env)
    for _, q in ipairs(node.quals) do
      if q.kind == "generator" then
        self:synth(q.source, s)
        self:declare(s, q.name, ANY, self:decl(q.name, "variable", q.name_tok, q))
        if q.value_name then
          self:declare(s, q.value_name, ANY, self:decl(q.value_name, "variable", q.value_name_tok, q))
        end
      else
        self:synth(q.cond, s)
      end
    end
    if k == "comprehension" then self:synth(node.yield, s)
    else self:synth(node.key, s); self:synth(node.value, s) end
    return ANY
  end
  if k == "range" then self:synth(node.from, env); self:synth(node.to, env); return ANY end
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
  if node.pattern then
    -- destructuring let: check the value (so type errors inside it still surface), and
    -- declare the bound names as `any` (dynamic this cycle — no typed destructuring yet)
    self:synth(node.value, env)
    self:declare_pattern(node.pattern, env)
    return
  end
  if node.param_types then for _, t in pairs(node.param_types) do self:bind_annotation(t) end end
  self:bind_annotation(node.ret_type)
  self:bind_annotation(node.value_type)
  if node.params then
    self:declare(env, node.name, self:decl_type(node), self:let_decl(node))   -- declare first (recursion)
    local s = scope(env)
    for i = 1, #node.params do
      local tok = node.param_toks and node.param_toks[i]
      self:declare(s, node.params[i], to_type(node.param_types and node.param_types[i]),
        tok and self:decl(node.params[i], "parameter", tok, node))
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
        table.insert(self.diags, mark + 1, errors.new(msg, node.line or 1, node.col or 1, nil, node.end_line, node.end_col))
      end
    end
  else
    local vt = self:synth(node.value, env)
    if node.value_type then
      local dt = to_type(node.value_type)
      if not consistent(vt, dt) then
        self:err("'" .. node.name .. "' is declared " .. tyname(dt) .. " but assigned " .. tyname(vt), node)
      end
      self:declare(env, node.name, dt, self:let_decl(node))
    else
      self:declare(env, node.name, vt, self:let_decl(node))
    end
  end
end

function M.check(program)
  local c = new_checker()
  c:build_registry(program)
  local genv = scope(nil)
  -- pass 1: declare all top-level binding types (so calls resolve regardless of order)
  for _, node in ipairs(program.stmts) do
    if node.kind == "let" then
      if node.pattern then
        -- destructuring let: declare each bound name as `any` (dynamic this cycle)
        c:declare_pattern(node.pattern, genv)
      else
        c:declare(genv, node.name, c:decl_type(node), c:let_decl(node))
      end
    end
  end
  -- pass 2: check bodies (check_binding re-declares, which is fine/idempotent)
  for _, node in ipairs(program.stmts) do
    if node.kind == "let" then c:check_binding(node, genv)
    elseif node.kind ~= "type_decl" then c:synth(node, genv) end
  end
  return c.diags, c.binding_of, c.type_of
end

return M
