# Positional Constructors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add positional-payload constructors to sum types — `type Option = Some(a) | None`, build `Some(3)`, match `Some(x)` — coexisting with named (`Circle { radius }`) and nullary (`None`) constructors.

**Architecture:** Parens mean positional, braces mean named, bare means nullary — a parallel shape through the parser (declaration/construct/pattern), codegen (`{ __tag, <args…> }` array part; `[i]` pattern access), and the typecheck registry/validation (arity + named-vs-positional shape). Runtime stays dynamic; exhaustiveness keys on `__tag` unchanged.

**Tech Stack:** Pure Lua (LuaJIT + Lua 5.4 in CI); `omelette.parser` / `omelette.codegen` / `omelette.typecheck` / `omelette.compiler`; `spec/support/harness.lua`.

## Global Constraints

- Runs on both LuaJIT and Lua 5.4 (CI matrix).
- Three constructor shapes are mutually exclusive per constructor: **positional** `Ctor(slot, …)`, **named** `Ctor { field, … }`, **nullary** `Ctor`. `Ctor()` (empty parens) is arity 0.
- Positional slot identifiers in a declaration are used only for their **count (arity)** this cycle (erased; reserved for future field types).
- Runtime rep: `Some(3)` → `{ __tag = "Some", 3 }` (args in the Lua array part; `__tag` in the hash part).
- Node/registry shapes (use verbatim):
  - variant (decl): named `{ name, fields = {…} }`; positional `{ name, positional = true, arity = N }`; nullary `{ name, fields = {} }`.
  - `construct` node: named `{ kind="construct", tag, fields = {…} }`; positional `{ kind="construct", tag, positional = true, args = {…} }`.
  - `ctor_pat` node: named `{ kind="ctor_pat", tag, fields = {…} }`; positional `{ kind="ctor_pat", tag, positional = true, args = {…} }`.
  - `ctor_owner[name]`: named `{ type, fields, fieldset }`; positional `{ type, positional = true, arity }`.
- `compiler.eval(src)` → module table; `compiler.compile(src)` → `lua, nil` | `nil, err` (err.message a string). Harness: `require("spec.support.harness")` (`h.describe/it/eq/truthy`). Run: `luajit spec/run.lua`.

---

### Task 1: Parser — positional declaration, construct, and pattern

**Files:**
- Modify: `omelette/parser.lua` (`parse_type_decl`; the uppercase-ident construct branch in `parse_primary`; the ctor-pattern branch in `parse_pattern`)
- Test: `spec/positional_ctor_parser_spec.lua`

**Interfaces:**
- Produces: positional variant/construct/ctor_pat nodes per the shapes in Global Constraints — consumed by Tasks 2 and 3.

- [ ] **Step 1: Write the failing tests**

Create `spec/positional_ctor_parser_spec.lua`:

```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local function prog(s) return assert(parser.parse(s)) end
local function ex(s) return assert(parser.parse_expr_string(s)) end

h.describe("positional constructors — parsing", function()
  h.it("declares a positional variant with an arity", function()
    local td = prog("type Option = Some(a) | None").stmts[1]
    h.eq(td.variants[1].name, "Some")
    h.truthy(td.variants[1].positional)
    h.eq(td.variants[1].arity, 1)
    h.truthy(td.variants[2].positional == nil)   -- None is nullary
  end)
  h.it("declares a 2-arity positional variant", function()
    local td = prog("type Tree = Leaf(v) | Node(l, r)").stmts[1]
    h.eq(td.variants[2].arity, 2)
  end)
  h.it("parses positional construction `Some(3)`", function()
    local e = ex("Some(3)")
    h.eq(e.kind, "construct")
    h.truthy(e.positional)
    h.eq(#e.args, 1)
    h.eq(e.args[1].kind, "number")
  end)
  h.it("named construction still parses", function()
    local e = ex("Circle { radius = 3 }")
    h.eq(e.kind, "construct")
    h.truthy(e.positional == nil)
    h.eq(e.fields[1].key, "radius")
  end)
  h.it("parses a positional constructor pattern", function()
    local node = prog("let f x = match x with | Some(v) -> v | None -> 0").stmts[1]
    -- dig to the match's first case pattern
    local m = node.value
    h.eq(m.cases[1].pattern.kind, "ctor_pat")
    h.truthy(m.cases[1].pattern.positional)
    h.eq(#m.cases[1].pattern.args, 1)
  end)
end)
```

- [ ] **Step 2: Run to verify they fail**

Run: `luajit spec/run.lua 2>&1 | grep -iE "positional constructors — parsing|fail" | head`
Expected: FAIL — positional forms aren't parsed (`Some(3)` currently becomes a nullary `Some` followed by a call).

- [ ] **Step 3: Declaration — positional variant in `parse_type_decl`**

In `omelette/parser.lua`, in `Parser:parse_type_decl()`, replace the per-variant field block:

```lua
    local vfields = {}
    if self:at("punct", "{") then
      self:next()
      if not self:at("punct", "}") then
        repeat vfields[#vfields + 1] = self:expect("ident").value until not self:accept_comma()
      end
      self:expect("punct", "}")
    end
    variants[#variants + 1] = { name = cname.value, fields = vfields }
```

with one that also handles a positional `( … )` form:

```lua
    if self:at("punct", "(") then
      self:next()
      local arity = 0
      if not self:at("punct", ")") then
        repeat self:expect("ident"); arity = arity + 1 until not self:accept_comma()
      end
      self:expect("punct", ")")
      variants[#variants + 1] = { name = cname.value, positional = true, arity = arity }
    else
      local vfields = {}
      if self:at("punct", "{") then
        self:next()
        if not self:at("punct", "}") then
          repeat vfields[#vfields + 1] = self:expect("ident").value until not self:accept_comma()
        end
        self:expect("punct", "}")
      end
      variants[#variants + 1] = { name = cname.value, fields = vfields }
    end
```

- [ ] **Step 4: Construction — positional in `parse_primary`**

In the uppercase-ident constructor branch of `parse_primary` (`if t.value:sub(1, 1):match("%u") then`), add a positional check **before** the named-`{` block, and keep the named/nullary return:

```lua
      -- uppercase ident = constructor
      if self:at("punct", "(") then
        self:next()
        local args = {}
        if not self:at("punct", ")") then
          repeat args[#args + 1] = self:parse_expr() until not self:accept_comma()
        end
        self:expect("punct", ")")
        return { kind = "construct", tag = t.value, positional = true, args = args, line = t.line, col = t.col }
      end
      local fields = {}
      if self:at("punct", "{") then
        self:next()
        if not self:at("punct", "}") then
          repeat
            local key = self:expect("ident").value
            self:expect("op", "=")
            local value = self:parse_expr()
            fields[#fields + 1] = { key = key, value = value }
          until not self:accept_comma()
        end
        self:expect("punct", "}")
      end
      return { kind = "construct", tag = t.value, fields = fields, line = t.line, col = t.col }
```

(The `(` here follows an already-consumed uppercase ident, so it does not collide with the tuple `(` branch, which fires only when a primary *starts* with `(`.)

- [ ] **Step 5: Pattern — positional in `parse_pattern`**

In the uppercase-ident constructor-pattern branch of `parse_pattern` (after `local id = self:expect("ident")` with an uppercase id), add a positional check before the named-`{` block:

```lua
    -- uppercase = constructor pattern
    if self:at("punct", "(") then
      self:next()
      local args = {}
      if not self:at("punct", ")") then
        repeat args[#args + 1] = self:parse_pattern() until not self:accept_comma()
      end
      self:expect("punct", ")")
      return { kind = "ctor_pat", tag = id.value, positional = true, args = args }
    end
    local fields = {}
    if self:at("punct", "{") then
      self:next()
      if not self:at("punct", "}") then
        repeat
          local key = self:expect("ident").value
          local p
          if self:at("op", ":") then self:next(); p = self:parse_pattern()
          else p = { kind = "var", name = key } end
          fields[#fields + 1] = { key = key, pat = p }
        until not self:accept_comma()
      end
      self:expect("punct", "}")
    end
    return { kind = "ctor_pat", tag = id.value, fields = fields }
```

- [ ] **Step 6: Run to verify pass, then commit**

Run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: full suite passes, 0 failures.

```bash
git add omelette/parser.lua spec/positional_ctor_parser_spec.lua
git commit -m "feat(parser): positional constructors (decl, construct, pattern)"
```

---

### Task 2: Codegen — positional emission + pattern + remove obsolete rejection

**Files:**
- Modify: `omelette/codegen.lua` (the `construct` case; the `ctor_pat` branch in `compile_pattern`; remove the `gen_call` constructor rejection)
- Test: `spec/positional_ctor_spec.lua`

**Interfaces:**
- Consumes: positional `construct` (`node.positional`, `node.args`) and `ctor_pat` (`pat.positional`, `pat.args`) from Task 1.

- [ ] **Step 1: Write the failing tests**

Create `spec/positional_ctor_spec.lua`:

```lua
local h = require("spec.support.harness")
local compiler = require("omelette.compiler")
local function eval(src) return assert(compiler.eval(src)) end

h.describe("positional constructors — runtime", function()
  h.it("builds and matches a 1-arity positional constructor", function()
    h.eq(eval([[
type Option = Some(a) | None
let unwrap o = match o with | Some(x) -> x | None -> 0
pub let r = unwrap(Some(7))
]]).r, 7)
  end)
  h.it("builds and matches a 2-arity positional constructor", function()
    h.eq(eval([[
type Pair = Pair(a, b)
let sum p = match p with | Pair(x, y) -> x + y
pub let r = sum(Pair(3, 4))
]]).r, 7)
  end)
  h.it("a wildcard ignores a positional slot", function()
    h.eq(eval([[
type Pair = Pair(a, b)
pub let r = match Pair(3, 4) with | Pair(_, y) -> y
]]).r, 4)
  end)
  h.it("nullary and positional coexist; None matches", function()
    h.eq(eval([[
type Option = Some(a) | None
pub let r = match None with | Some(x) -> x | None -> 99
]]).r, 99)
  end)
  h.it("the runtime rep puts the payload in the array part with __tag", function()
    local m = eval([[
type Option = Some(a) | None
pub let v = Some(5)
]])
    h.eq(m.v.__tag, "Some")
    h.eq(m.v[1], 5)
  end)
  h.it("positional and named constructors in one type both work", function()
    h.eq(eval([[
type Shape = Dot(x) | Circle { radius }
let area s = match s with | Dot(_) -> 0 | Circle { radius } -> radius * radius
pub let r = area(Circle { radius = 3 }) + area(Dot(9))
]]).r, 9)
  end)
  h.it("the emitted Lua loads", function()
    local lua = assert(compiler.compile("type T = A(x)\npub let v = A(1)"))
    local load_fn = loadstring or load
    h.truthy((load_fn(lua)))
  end)
end)
```

- [ ] **Step 2: Run to verify they fail**

Run: `luajit spec/run.lua 2>&1 | grep -iE "positional constructors — runtime|fail" | head`
Expected: FAIL — codegen has no positional `construct`/`ctor_pat` handling.

- [ ] **Step 3: Positional construct emission**

In `omelette/codegen.lua`, replace the `construct` case:

```lua
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
```

with one that handles the positional shape:

```lua
  if k == "construct" then
    local parts = { "__tag = " .. quote_string(node.tag) }
    if node.positional then
      for _, a in ipairs(node.args) do parts[#parts + 1] = expr(a, ctx) end
    else
      for _, f in ipairs(node.fields) do
        if f.key == "__tag" then
          error("field name '__tag' is reserved (it holds the constructor discriminant)")
        end
        parts[#parts + 1] = f.key .. " = " .. expr(f.value, ctx)
      end
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
```

- [ ] **Step 4: Positional constructor pattern**

In `compile_pattern`, replace the `ctor_pat` branch:

```lua
  elseif k == "ctor_pat" then
    tests[#tests + 1] = "type(" .. access .. ') == "table"'
    tests[#tests + 1] = access .. ".__tag == " .. quote_string(pat.tag)
    for _, f in ipairs(pat.fields) do
      compile_pattern(f.pat, access .. "." .. f.key, ctx, tests, binds)
    end
  end
```

with one that handles positional args:

```lua
  elseif k == "ctor_pat" then
    tests[#tests + 1] = "type(" .. access .. ') == "table"'
    tests[#tests + 1] = access .. ".__tag == " .. quote_string(pat.tag)
    if pat.positional then
      for i, sub in ipairs(pat.args) do
        compile_pattern(sub, access .. "[" .. i .. "]", ctx, tests, binds)
      end
    else
      for _, f in ipairs(pat.fields) do
        compile_pattern(f.pat, access .. "." .. f.key, ctx, tests, binds)
      end
    end
  end
```

- [ ] **Step 5: Remove the obsolete `gen_call` constructor rejection**

In `local function gen_call(node, ctx)`, delete the now-dead rejection block (a `Ctor(args)` is parsed as a positional construct in Task 1, so a `construct` node never reaches `gen_call`):

```lua
  if node.fn.kind == "construct" then
    -- `Some(x)` (reflexive ML call syntax) — constructors use named-field braces
    error("constructor '" .. node.fn.tag .. "' is built with braces, not call syntax: "
      .. "write " .. node.fn.tag .. " { field = ... }, not " .. node.fn.tag .. "(...)")
  end
```

- [ ] **Step 6: Run to verify pass, then commit**

Run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: full suite passes, 0 failures.

```bash
git add omelette/codegen.lua spec/positional_ctor_spec.lua
git commit -m "feat(codegen): positional constructor build + match; drop obsolete Ctor(...) rejection"
```

---

### Task 3: Typecheck — registry, arity, shape-mismatch + guide

**Files:**
- Modify: `omelette/typecheck.lua` (`build_registry`; `collect_pattern_vars`; the `construct` case in `synth`; `validate_pattern`)
- Test: `spec/positional_ctor_check_spec.lua`
- Modify: `docs/guide.md` (one verified example)

**Interfaces:**
- Consumes: positional variant/construct/ctor_pat nodes; produces registry entries `{ type, positional = true, arity }` and blocking diagnostics.

- [ ] **Step 1: Write the failing tests**

Create `spec/positional_ctor_check_spec.lua`:

```lua
local h = require("spec.support.harness")
local compiler = require("omelette.compiler")
-- opts.check = true runs the checker; compile returns nil,err on a diagnostic
local function check(src) return compiler.compile(src, { check = true }) end

h.describe("positional constructors — checking", function()
  h.it("accepts a correct-arity construction and match", function()
    local ok = check([[
type Option = Some(a) | None
let f o = match o with | Some(x) -> x | None -> 0
pub let r = f(Some(1))
]])
    h.truthy(ok)
  end)
  h.it("rejects wrong-arity construction", function()
    local ok, err = check("type Pair = Pair(a, b)\npub let v = Pair(1)")
    h.truthy(not ok)
    h.truthy(err.message:find("argument", 1, true))
  end)
  h.it("rejects wrong-arity pattern", function()
    local ok, err = check([[
type Pair = Pair(a, b)
let f p = match p with | Pair(x) -> x
pub let r = f(Pair(1, 2))
]])
    h.truthy(not ok)
    h.truthy(err.message:find("argument", 1, true))
  end)
  h.it("rejects named syntax on a positional constructor", function()
    local ok, err = check("type Option = Some(a) | None\npub let v = Some { a = 1 }")
    h.truthy(not ok)
    h.truthy(err.message:find("positional", 1, true))
  end)
  h.it("rejects positional syntax on a named constructor", function()
    local ok, err = check("type Shape = Circle { radius }\npub let v = Circle(3)")
    h.truthy(not ok)
    h.truthy(err.message:find("named", 1, true))
  end)
  h.it("checks exhaustiveness over positional constructors", function()
    local ok, err = check([[
type Option = Some(a) | None
let f o = match o with | Some(x) -> x
pub let r = f(Some(1))
]])
    h.truthy(not ok)
    h.truthy(err.message:find("exhaustive", 1, true))
  end)
end)
```

- [ ] **Step 2: Run to verify they fail**

Run: `luajit spec/run.lua 2>&1 | grep -iE "positional constructors — checking|fail" | head`
Expected: FAIL — some cases error out (the registry does not record positional constructors, so `collect_pattern_vars` may crash on `ipairs(nil)` and the validations are missing).

- [ ] **Step 3: Registry — positional entries in `build_registry`**

In `omelette/typecheck.lua`, in `build_registry`, replace the per-variant registration:

```lua
        entry.ctors[#entry.ctors + 1] = v.name
        entry.fields[v.name] = v.fields
        local fieldset = {}
        for _, f in ipairs(v.fields) do fieldset[f] = true end
        self.ctor_owner[v.name] = { type = node.name, fields = v.fields, fieldset = fieldset }
```

with:

```lua
        entry.ctors[#entry.ctors + 1] = v.name
        if v.positional then
          self.ctor_owner[v.name] = { type = node.name, positional = true, arity = v.arity }
        else
          entry.fields[v.name] = v.fields
          local fieldset = {}
          for _, f in ipairs(v.fields) do fieldset[f] = true end
          self.ctor_owner[v.name] = { type = node.name, fields = v.fields, fieldset = fieldset }
        end
```

- [ ] **Step 4: `collect_pattern_vars` — handle positional ctor_pat (prevents a crash)**

Find the `ctor_pat` line in `collect_pattern_vars`:

```lua
  elseif k == "ctor_pat" then for _, f in ipairs(pat.fields) do collect_pattern_vars(f.pat, out) end
```

replace with:

```lua
  elseif k == "ctor_pat" then
    if pat.positional then for _, p in ipairs(pat.args) do collect_pattern_vars(p, out) end
    else for _, f in ipairs(pat.fields) do collect_pattern_vars(f.pat, out) end end
```

- [ ] **Step 5: `synth` construct — arity + shape mismatch**

Replace the `construct` case in `synth`:

```lua
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
```

with a version that branches on positional:

```lua
  if k == "construct" then
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
```

- [ ] **Step 6: `validate_pattern` — arity + shape mismatch**

Replace the `ctor_pat` branch in `validate_pattern`:

```lua
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
```

with a version that branches on positional:

```lua
  if k == "ctor_pat" then
    local owner = self.ctor_owner[pat.tag]
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
```

(Exhaustiveness (`check_exhaustive`) is unchanged — it keys on `pat.tag`, which positional `ctor_pat` nodes also carry.)

- [ ] **Step 7: Run to verify pass**

Run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: full suite passes, 0 failures.

- [ ] **Step 8: Add a guide example and verify the doctest**

In `docs/guide.md`, in the sum-types section, add:

````markdown
Constructors can take positional arguments instead of named fields:

```egg
type Option = Some(a) | None
let unwrap o fallback =
  match o with
  | Some(x) -> x
  | None    -> fallback
print(unwrap(Some(7), 0))
```
```output
7
```
````

Then run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: still 0 failures — the doctest harness compiled and ran the new example and matched its `output` (`7`).

- [ ] **Step 9: Commit**

```bash
git add omelette/typecheck.lua spec/positional_ctor_check_spec.lua docs/guide.md
git commit -m "feat(typecheck): positional constructor arity + shape-mismatch validation"
```

---

## Post-merge (not a plan task)

Update `docs/ROADMAP.md`: move "Positional constructors" to Shipped (with tuples, closes the "Positional constructors + tuples" item). This completes the Now/Next roadmap tier (or-patterns / as-patterns remain the only deferred pattern-matching-extras work).
