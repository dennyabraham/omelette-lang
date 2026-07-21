# Omelette Optional Typing (Cycle 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional, erased static typing — parse `:` annotations, check primitives + function types + `any` at dev/build time, erase in codegen.

**Architecture:** Task 1 adds the `:` token, a `parse_type()`, and typed-param/return/value annotations on `let` (new AST fields, codegen ignores them). Task 2 adds a self-contained `omelette/typecheck.lua` (type representation, consistency, bottom-up synthesis, two-pass module checking). Task 3 wires it in as opt-in dev/build-time checking: `compiler.check`, `compile(src, {check=true})`, an `omelette check` CLI command and `--no-check` — while the runtime `compile()`/searcher/embed/REPL paths never check.

**Tech Stack:** Pure Lua compiler, tested with the in-repo harness under `luajit`.

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline**. Test runner is `luajit spec/run.lua`.
- Typing is **optional and erased**: annotations parse into AST fields that **codegen ignores** — generated Lua is byte-identical with or without annotations.
- The only new token is **`:`**. Type names (`number`/`string`/`boolean`/`any`) are ordinary idents in annotation position (not reserved words); `nil` (existing keyword) is the nil type. Unknown type names → treated as `any` (lenient; forward-compatible with cycle 2).
- Function type syntax: **`(T1, T2) -> R`**.
- `any` is consistent with every type; a type error arises only between two *known* (non-`any`) inconsistent types.
- Checking is **opt-in, dev/build-time only.** `resolver.resolve` stays a light identity pass; the checker is a separate module the *compiler* calls only when `opts.check` is set (and `omelette check`). Runtime paths (searcher, `eval`, REPL) never check → erase-and-run.

---

## Data Structures (authoritative reference)

Parse-type AST nodes (Task 1, consumed by Task 2):
```lua
{ kind = "type_name", name = <string> }               -- "number"/"string"/"boolean"/"nil"/"any"/unknown
{ kind = "fun_type", params = { <type-node>... }, ret = <type-node> }
```
`let` node gains (Task 1): `param_types` (array parallel to `params`; each entry is a type-node or `false` for an untyped param), `ret_type` (type-node or nil), `value_type` (type-node or nil). `params`/`param_types` are both nil for value bindings.

Type representation (Task 2): `{kind="number"|"string"|"boolean"|"nil"|"any"}` and `{kind="fun", params={<type>...}, ret=<type>}`.

---

### Task 1: Annotation parsing (`:` token, `parse_type`, typed `let`)

**Files:**
- Modify: `omelette/lexer.lua:13` (add `:` to `SINGLE_OPS`)
- Modify: `omelette/parser.lua` (add `Parser:parse_type`; rewrite `Parser:parse_let`)
- Create: `spec/annotation_spec.lua`

**Interfaces:**
- Produces: `parse_type` nodes and the new `let` fields above. Codegen unchanged (erasure).

- [ ] **Step 1: Write the failing test**

`spec/annotation_spec.lua`:
```lua
local h = require("spec.support.harness")
local lexer = require("omelette.lexer")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local function prog(s) return assert(parser.parse(s)) end

h.describe("annotations", function()
  h.it("lexes : as an op", function()
    local toks = assert(lexer.tokenize("x : number"))
    h.eq(toks[2], { type = "op", value = ":", line = 1, col = 3 })
  end)
  h.it("parses a typed value binding", function()
    local e = prog("let count: number = 0").stmts[1]
    h.eq(e.value_type, { kind = "type_name", name = "number" })
    h.eq(e.params, nil)
  end)
  h.it("parses typed params and a return type", function()
    local e = prog("let add (x: number) (y: number): number = x + y").stmts[1]
    h.eq(e.params, { "x", "y" })
    h.eq(e.param_types[1], { kind = "type_name", name = "number" })
    h.eq(e.param_types[2], { kind = "type_name", name = "number" })
    h.eq(e.ret_type, { kind = "type_name", name = "number" })
  end)
  h.it("mixes typed and untyped params (untyped => false)", function()
    local e = prog("let f (x: number) y = x").stmts[1]
    h.eq(e.params, { "x", "y" })
    h.eq(e.param_types[1], { kind = "type_name", name = "number" })
    h.eq(e.param_types[2], false)
  end)
  h.it("parses a function type annotation", function()
    local e = prog("let g: (number, string) -> boolean = h").stmts[1]
    h.eq(e.value_type.kind, "fun_type")
    h.eq(#e.value_type.params, 2)
    h.eq(e.value_type.params[1].name, "number")
    h.eq(e.value_type.ret, { kind = "type_name", name = "boolean" })
  end)
  h.it("still parses untyped defs (regression)", function()
    local e = prog("let f x y = x + y").stmts[1]
    h.eq(e.params, { "x", "y" })
    h.eq(e.param_types, nil)
  end)
  h.it("ERASURE: annotated program emits identical Lua to unannotated", function()
    local typed = codegen.program(prog("pub let add (x: number) (y: number): number = x + y"))
    local plain = codegen.program(prog("pub let add x y = x + y"))
    h.eq(typed, plain)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `:` is an unexpected character; the annotation assertions fail.

- [ ] **Step 3: Implement**

In `omelette/lexer.lua`, change `SINGLE_OPS` (line 13) to add `:`:
```lua
local SINGLE_OPS = { ["+"]=true,["-"]=true,["*"]=true,["/"]=true,["%"]=true,
  ["<"]=true,[">"]=true,["="]=true,["#"]=true,[":"]=true }
```

In `omelette/parser.lua`, add a `Parser:parse_type` method (place it near the other `Parser:` methods, e.g. just before `Parser:parse_let`):
```lua
-- parse a type expression (only in annotation position): a type name
-- (number/string/boolean/any/… as idents, or the nil keyword), or a function
-- type `(T1, T2) -> R`.
function Parser:parse_type()
  if self:at("punct", "(") then
    self:next()
    local params = {}
    if not self:at("punct", ")") then
      repeat params[#params + 1] = self:parse_type() until not self:accept_comma()
    end
    self:expect("punct", ")")
    self:expect("op", "->")
    local ret = self:parse_type()
    return { kind = "fun_type", params = params, ret = ret }
  end
  if self:at("keyword", "nil") then
    self:next()
    return { kind = "type_name", name = "nil" }
  end
  local id = self:expect("ident")
  return { kind = "type_name", name = id.value }
end
```

Replace `Parser:parse_let` with the annotation-aware version:
```lua
function Parser:parse_let()
  local is_pub = false
  local startt = self:peek()
  if self:at("keyword", "pub") then is_pub = true; self:next() end
  self:expect("keyword", "let")
  local name = self:expect("ident").value
  -- params: bare `ident` (untyped -> false) or parenthesized `(ident: type)`
  local params, param_types = nil, nil
  while self:at("ident") or self:at("punct", "(") do
    params = params or {}
    param_types = param_types or {}
    if self:at("punct", "(") then
      self:next()
      local pname = self:expect("ident").value
      self:expect("op", ":")
      local ptype = self:parse_type()
      self:expect("punct", ")")
      params[#params + 1] = pname
      param_types[#params] = ptype
    else
      params[#params + 1] = self:next().value
      param_types[#params] = false
    end
  end
  -- return type (functions) or value-binding type
  local ret_type, value_type = nil, nil
  if self:at("op", ":") then
    self:next()
    local t = self:parse_type()
    if params then ret_type = t else value_type = t end
  end
  self:expect("op", "=")
  local value = self:parse_block_or_expr()
  return { kind = "let", name = name, params = params, param_types = param_types,
           ret_type = ret_type, value_type = value_type,
           is_pub = is_pub, line = startt.line, col = startt.col }
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — annotation parser tests green (incl. the ERASURE test proving codegen output is byte-identical); all prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add omelette/lexer.lua omelette/parser.lua spec/annotation_spec.lua
git commit -m "feat: parse optional type annotations (: token, parse_type, typed let)"
```

---

### Task 2: The type checker (`omelette/typecheck.lua`)

**Files:**
- Create: `omelette/typecheck.lua`
- Create: `spec/typecheck_spec.lua`

**Interfaces:**
- Consumes: the annotated `let` fields + `parse_type` nodes (Task 1), `omelette.parser`, `omelette.errors`.
- Produces: `typecheck.check(program) -> diagnostics` — a list of `{message, line, col}` (empty if clean).

- [ ] **Step 1: Write the failing test**

`spec/typecheck_spec.lua`:
```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local tc = require("omelette.typecheck")
local function diags(s) return tc.check(assert(parser.parse(s))) end
local function ok(s) h.eq(#diags(s), 0) end
local function bad(s, needle)
  local d = diags(s)
  h.truthy(#d >= 1)
  h.truthy(d[1].message:find(needle, 1, true))
end

h.describe("typecheck", function()
  h.it("clean annotated program has no diagnostics", function()
    ok("pub let add (x: number) (y: number): number = x + y")
    ok('pub let greet (name: string): string = "hi " .. name')
    ok("let count: number = 0")
  end)
  h.it("value binding mismatch", function()
    bad('let x: number = "hi"', "number")
  end)
  h.it("function return mismatch", function()
    bad('let f (x: number): number = x .. "!"', "returns")
  end)
  h.it("arithmetic on a string operand", function()
    bad("let f (s: string): number = s + 1", "number")
  end)
  h.it("concat on a number operand", function()
    bad('let f (n: number): string = n .. "x"', "string")
  end)
  h.it("call argument mismatch against an annotated function", function()
    bad(table.concat({
      "let add (x: number) (y: number): number = x + y",
      'let bad = add(1, "x")',
    }, "\n"), "argument 2")
  end)
  h.it("call arity mismatch", function()
    bad(table.concat({
      "let add (x: number) (y: number): number = x + y",
      "let bad = add(1)",
    }, "\n"), "argument")
  end)
  h.it("any / unannotated / interop never error", function()
    ok("let f x y = x + y")                                   -- untyped params are any
    ok('let r = vim.api.foo(1, "x", true)')                   -- Lua interop is any
    ok(table.concat({
      "let g x = x",                                          -- unannotated fn -> any-typed
      'let r = g("anything")',
    }, "\n"))
  end)
  h.it("clean program with a partial-application hole is not arg-checked", function()
    ok(table.concat({
      "let add (x: number) (y: number): number = x + y",
      "let inc = add(1, _)",
    }, "\n"))
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `module 'omelette.typecheck' not found`.

- [ ] **Step 3: Implement `omelette/typecheck.lua`**

```lua
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
      local bt = self:synth(c.body, env)
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
    local bodyt = self:synth(node.value, s)
    if node.ret_type then
      local rt = to_type(node.ret_type)
      if not consistent(bodyt, rt) then
        self:err("function '" .. node.name .. "' returns " .. tyname(bodyt) .. ", declared " .. tyname(rt), node)
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
  local genv = scope(nil)
  -- pass 1: declare all top-level binding types (so calls resolve regardless of order)
  for _, node in ipairs(program.stmts) do
    if node.kind == "let" then genv.vars[node.name] = c:decl_type(node) end
  end
  -- pass 2: check bodies (check_binding re-declares, which is fine/idempotent)
  for _, node in ipairs(program.stmts) do
    if node.kind == "let" then c:check_binding(node, genv)
    else c:synth(node, genv) end
  end
  return c.diags
end

return M
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — typecheck unit tests green (good programs clean; bad programs produce the expected diagnostics; any/interop/holes never error); all prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add omelette/typecheck.lua spec/typecheck_spec.lua
git commit -m "feat: optional type checker (primitives + function types + any)"
```

---

### Task 3: Wiring — opt-in checking, `omelette check`, `--no-check`

**Files:**
- Modify: `omelette/compiler.lua` (add `check`; add `opts.check` to `compile`)
- Modify: `omelette/cli.lua` (add `check` subcommand; `--no-check` on `build`/`run`)
- Create: `spec/typecheck_wiring_spec.lua`

**Interfaces:**
- Consumes: `typecheck.check` (Task 2).
- Produces: `compiler.check(source) -> diagnostics, err`; `compiler.compile(source, opts)` blocks on the first type diagnostic when `opts.check`. CLI `check` and `--no-check`.

- [ ] **Step 1: Write the failing test**

`spec/typecheck_wiring_spec.lua`:
```lua
local h = require("spec.support.harness")
local compiler = require("omelette.compiler")

h.describe("typecheck wiring", function()
  h.it("compile() without opts never checks (erase-and-run)", function()
    -- a type error, but no check requested -> compiles fine
    local lua, err = compiler.compile('let x: number = "hi"')
    h.truthy(err == nil)
    h.truthy(lua:find('local x = "hi"'))
  end)
  h.it("compile(src, {check=true}) blocks on a type error", function()
    local lua, err = compiler.compile('let x: number = "hi"', { check = true })
    h.truthy(lua == nil)
    h.truthy(err ~= nil)
    h.truthy(err.message:find("number", 1, true))
  end)
  h.it("compile(src, {check=true}) passes a clean program through to Lua", function()
    local lua, err = compiler.compile("pub let add (x: number) (y: number): number = x + y", { check = true })
    h.truthy(err == nil)
    h.truthy(lua:find("function add"))
  end)
  h.it("check(src) returns all diagnostics", function()
    local d = assert(compiler.check('let x: number = "hi"'))
    h.truthy(#d >= 1)
    h.truthy(d[1].message:find("number", 1, true))
  end)
  h.it("check(src) on a clean program returns an empty list", function()
    h.eq(#assert(compiler.check("let count: number = 0")), 0)
  end)
  h.it("eval() still runs a type-erroneous program (runtime path never checks)", function()
    local mod = assert(compiler.eval('pub let x: number = "hi"'))
    h.eq(mod.x, "hi")
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `compiler.check` is nil; `compile` ignores `opts`.

- [ ] **Step 3: Implement**

In `omelette/compiler.lua`, replace `M.compile` and add `M.check` (keep `M.eval` as-is; it calls `M.compile(source)` with no opts, so it never checks):
```lua
function M.check(source)
  local program, perr = parser.parse(source)
  if not program then return nil, perr end
  local typecheck = require("omelette.typecheck")
  return typecheck.check(program), nil
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
```

In `omelette/cli.lua`, add a `check` subcommand and a `--no-check` flag on build/run. First, add a helper and the command dispatch. Add this `cmd_check` function (next to the other `cmd_*` functions):
```lua
local function cmd_check(argv)
  local file = argv[2]
  local src = file and read_file(file)
  if not src then
    io.write(errors.render(errors.new("cannot read file '" .. tostring(file) .. "'", 1, 1)) .. "\n")
    return 1
  end
  local diags, err = compiler.check(src)
  if err then io.write(errors.render(err) .. "\n"); return 1 end
  if #diags == 0 then io.write("no type errors\n"); return 0 end
  for _, d in ipairs(diags) do io.write(errors.render(d) .. "\n") end
  return 1
end
```
Then, in `M.main`, add the `check` case and register it in the dispatch. Update `M.main` so it includes:
```lua
  if cmd == "check" then return cmd_check(argv) end
```
(place alongside the existing `build`/`run`/`repl` cases).

Finally, make `build`/`run` type-check by default unless `--no-check`. In `cmd_build`, where it currently calls `compiler.compile(src)`, change to:
```lua
  local lua, err = compiler.compile(src, { check = not has_flag(argv, "--no-check") })
```
and in `cmd_run`, change its `compiler.eval(src, file)` call to first compile-with-check, then eval the produced Lua. Replace the eval line in `cmd_run` with:
```lua
  local lua, cerr = compiler.compile(src, { check = not has_flag(argv, "--no-check") })
  if not lua then io.write(errors.render(cerr) .. "\n"); return 1 end
  local _, err = compiler.eval(src, file)   -- eval re-compiles without check; fine (already validated)
  if err then io.write(errors.render(err) .. "\n"); return 1 end
  return 0
```
(Update the `USAGE` string to mention `check` and `--no-check`.)

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Then smoke-test the CLI:
Run: `printf 'let x: number = "hi"\n' > /tmp/bad.egg && ./bin/omelette check /tmp/bad.egg; echo "exit=$?"`
Expected: tests PASS; `check` prints a `number`-mismatch diagnostic and `exit=1`.

- [ ] **Step 5: Commit**

```bash
git add omelette/compiler.lua omelette/cli.lua spec/typecheck_wiring_spec.lua
git commit -m "feat: opt-in type checking (omelette check, build/run --no-check)"
```

---

## Self-Review

**1. Spec coverage:**
- `:` token, `parse_type`, typed params/return/value, erasure → Task 1 (incl. the byte-identical erasure test). ✓
- Type rep, consistency (`any` universal), bottom-up synth, two-pass module check → Task 2. ✓
- Checks: value binding, function return, call args + arity, arithmetic/concat operators; any/interop/holes never error → Task 2 tests. ✓
- Opt-in dev/build-time only; runtime `compile()`/`eval` never check; `resolver` untouched → Task 3 (`compile` gates on `opts.check`; `eval` calls `compile` without opts). ✓
- `omelette check` + `build`/`run` block with `--no-check` → Task 3. ✓
- Deferred (arrays/records, inference, runtime checks, lambda annotations) → not implemented (correct). ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". Complete code + full test assertions in every step. The typecheck module is given in full.

**3. Type consistency:** The `parse_type` node shapes (`type_name`/`fun_type`) and the `let` fields (`param_types`/`ret_type`/`value_type`) produced in Task 1 are exactly what `to_type`/`decl_type`/`check_binding` consume in Task 2. `typecheck.check(program) -> diagnostics` (a `{message,line,col}` list) is what Task 3's `compiler.check`/`compile` consume. `param_types[i]` is a type-node or `false`; `to_type(false)`/`to_type(nil)` → `ANY`, matching the "untyped param is any" rule. ✓
