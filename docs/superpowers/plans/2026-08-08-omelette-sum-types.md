# Omelette Sum Types (Cycle 1: Runtime ADTs) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Runtime algebraic data types — `type` declarations, capitalized named-field constructors (`Circle { radius = 5 }` → `{ __tag = "Circle", radius = 5 }`), and constructor patterns in `match`.

**Architecture:** Task 1 (parser): `type` keyword, `parse_type_decl`, uppercase-ident construction in `parse_primary`, constructor patterns in `parse_pattern`. Task 2 (codegen): emit `construct` tables, `ctor_pat` tag-tests in `compile_pattern`, skip `type_decl` in `M.program`. Task 3 (typecheck): skip `type_decl`, synth `construct`, collect `ctor_pat` vars. Dynamic in cycle 1; the `type` declaration is erased.

**Tech Stack:** Pure Lua compiler, tested with the in-repo harness under `luajit`.

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline**. Test runner is `luajit spec/run.lua`.
- **Capitalization is the rule:** an uppercase-initial ident is a constructor (in expression AND pattern position); lowercase is a variable. Uppercase test: `s:sub(1,1):match("%u") ~= nil`.
- Runtime representation: `{ __tag = "<Ctor>", <field> = <v>, … }` (`__tag` namespaced).
- The `type` declaration is **erased** at codegen (cycle 1 is dynamic; typing/exhaustiveness deferred).
- No new false positives in the checker; the stdlib still checks clean.

---

## Data Structures (authoritative reference)

New AST nodes (Task 1; consumed by Tasks 2/3):
```lua
{ kind = "type_decl", name = <string>, is_pub = <bool>,
  variants = { { name = <string>, fields = { <string>… } }… }, line, col }   -- top-level stmt
{ kind = "construct", tag = <string>, fields = { { key = <string>, value = <expr> }… }, line, col }  -- expression
{ kind = "ctor_pat", tag = <string>, fields = { { key = <string>, pat = <pattern> }… } }             -- match pattern
```

---

### Task 1: Parser — `type` decl, construction, constructor patterns

**Files:**
- Modify: `omelette/lexer.lua` (add `type` to `KEYWORDS`)
- Modify: `omelette/parser.lua` (add `Parser:parse_type_decl`; dispatch it from `parse_statement`; uppercase-ident construction in `parse_primary`; constructor patterns in `parse_pattern`)
- Create: `spec/sumtype_parse_spec.lua`

**Interfaces:**
- Produces the `type_decl`/`construct`/`ctor_pat` AST above. Codegen/typecheck unchanged in this task (existing code uses no uppercase idents, so nothing regresses; new nodes are only asserted at the AST level here — do NOT compile a program containing them in Task 1 tests).

- [ ] **Step 1: Write the failing test**

`spec/sumtype_parse_spec.lua`:
```lua
local h = require("spec.support.harness")
local lexer = require("omelette.lexer")
local parser = require("omelette.parser")
local function stmt(s) return assert(parser.parse(s)).stmts[1] end
local function expr(s) return assert(parser.parse_expr_string(s)) end
local function pat(s) return assert(parser.parse("pub let f v = match v with " .. s)).stmts[1].value.cases[1].pattern end

h.describe("sum type parsing", function()
  h.it("lexes type as a keyword", function()
    local toks = assert(lexer.tokenize("type X"))
    h.eq(toks[1], { type = "keyword", value = "type", line = 1, col = 1 })
  end)
  h.it("parses a type declaration with named-field + nullary variants", function()
    local d = stmt("type Shape = | Circle { radius } | Rect { width, height } | Origin")
    h.eq(d.kind, "type_decl"); h.eq(d.name, "Shape"); h.eq(d.is_pub, false)
    h.eq(d.variants[1], { name = "Circle", fields = { "radius" } })
    h.eq(d.variants[2], { name = "Rect", fields = { "width", "height" } })
    h.eq(d.variants[3], { name = "Origin", fields = {} })
  end)
  h.it("parses pub type", function()
    local d = stmt("pub type Option = | Some { value } | None")
    h.eq(d.kind, "type_decl"); h.eq(d.is_pub, true); h.eq(d.name, "Option")
  end)
  h.it("rejects a lowercase constructor", function()
    local _, err = parser.parse("type Bad = | circle { r }")
    h.truthy(err ~= nil)
    h.truthy(err.message:find("capitalized"))
  end)
  h.it("parses construction (fields and nullary)", function()
    local e = expr("Circle { radius = 5 }")
    h.eq(e.kind, "construct"); h.eq(e.tag, "Circle")
    h.eq(e.fields[1].key, "radius"); h.eq(e.fields[1].value.value, 5)
    h.eq(expr("None"), { kind = "construct", tag = "None", fields = {}, line = 1, col = 1 })
  end)
  h.it("still parses a lowercase ident as an ident (regression)", function()
    h.eq(expr("radius").kind, "ident")
  end)
  h.it("parses constructor patterns (fields, nullary, nested rename)", function()
    local p = pat("| Some { value } -> value")
    h.eq(p.kind, "ctor_pat"); h.eq(p.tag, "Some")
    h.eq(p.fields[1], { key = "value", pat = { kind = "var", name = "value" } })
    h.eq(pat("| None -> 0"), { kind = "ctor_pat", tag = "None", fields = {} })
    local n = pat("| Some { value: [a, b] } -> a")
    h.eq(n.fields[1].pat.kind, "array_pat")
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `type` isn't a keyword; `Circle { … }` parses `Circle` as a plain ident (then chokes); the `type_decl`/`construct`/`ctor_pat` assertions fail.

- [ ] **Step 3: Implement**

In `omelette/lexer.lua`, add `["type"]=true` to `KEYWORDS`.

In `omelette/parser.lua`, add `Parser:parse_type_decl` (place near `parse_let`):
```lua
function Parser:parse_type_decl()
  local is_pub = false
  local startt = self:peek()
  if self:at("keyword", "pub") then is_pub = true; self:next() end
  self:expect("keyword", "type")
  local name = self:expect("ident").value
  self:expect("op", "=")
  local variants = {}
  if self:at("punct", "|") then self:next() end  -- optional leading |
  repeat
    local cname = self:expect("ident")
    if not cname.value:sub(1, 1):match("%u") then
      self:fail("constructor names must be capitalized")
    end
    local vfields = {}
    if self:at("punct", "{") then
      self:next()
      if not self:at("punct", "}") then
        repeat vfields[#vfields + 1] = self:expect("ident").value until not self:accept_comma()
      end
      self:expect("punct", "}")
    end
    variants[#variants + 1] = { name = cname.value, fields = vfields }
  until not (self:at("punct", "|") and self:next())
  return { kind = "type_decl", name = name, is_pub = is_pub, variants = variants,
           line = startt.line, col = startt.col }
end
```

Dispatch it from `Parser:parse_statement` (add the two `type` checks before the `pub`/`let` check):
```lua
function Parser:parse_statement()
  if self:at("keyword", "type") then return self:parse_type_decl() end
  if self:at("keyword", "pub") and self:peek2() and self:peek2().type == "keyword"
      and self:peek2().value == "type" then
    return self:parse_type_decl()
  end
  if self:at("keyword", "pub") or self:at("keyword", "let") then
    return self:parse_let()
  end
  return self:parse_expr()
end
```

Replace the `parse_primary` ident branch (`if t.type == "ident" then self:next(); return { kind = "ident", … } end`) with:
```lua
  if t.type == "ident" then
    self:next()
    if t.value:sub(1, 1):match("%u") then
      -- uppercase ident = constructor: `Ctor { field = v }` or bare nullary `Ctor`
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
    end
    return { kind = "ident", name = t.value, line = t.line, col = t.col }
  end
```

Replace the `parse_pattern` bare-ident tail (`local id = self:expect("ident"); return { kind = "var", … }`) with:
```lua
  local id = self:expect("ident")
  if id.value:sub(1, 1):match("%u") then
    -- uppercase = constructor pattern: `Ctor { field-pats }` or nullary `Ctor`
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
  end
  return { kind = "var", name = id.value }
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — sum-type parser tests green; all prior tests still green (no existing code uses uppercase idents or `type`).

- [ ] **Step 5: Commit**

```bash
git add omelette/lexer.lua omelette/parser.lua spec/sumtype_parse_spec.lua
git commit -m "feat: parse type declarations, construction, and constructor patterns"
```

---

### Task 2: Codegen — construction, constructor patterns, erased decl

**Files:**
- Modify: `omelette/codegen.lua` (`construct` in `expr`; `ctor_pat` in `compile_pattern`; skip `type_decl` in `M.program`)
- Create: `spec/sumtype_codegen_spec.lua`

**Interfaces:**
- Consumes the Task 1 AST + the existing match IIFE (`compile_pattern`/`gen_match`).
- Produces: `construct` → `{ __tag = … }`; `ctor_pat` → tag tests in a match; `type_decl` emits nothing.

- [ ] **Step 1: Write the failing golden + behavioral test**

`spec/sumtype_codegen_spec.lua`:
```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end
local function prog(s) return codegen.program(assert(parser.parse(s))) end

h.describe("sum type codegen", function()
  h.it("emits a tagged table for construction", function()
    h.eq(gen("Circle { radius = 5 }"), '{ __tag = "Circle", radius = 5 }')
    h.eq(gen("None"), '{ __tag = "None" }')
  end)
  h.it("emits nothing for a type declaration (erased)", function()
    local out = prog("type Shape = | Circle { radius } | Origin")
    h.truthy(not out:find("Shape"))
    h.truthy(not out:find("__tag"))    -- decl alone emits no runtime code
    h.truthy(out:find("local M = {}"))
  end)
  h.it("a constructor pattern tests type + __tag", function()
    local out = gen("match v with | Some { value } -> value | None -> 0")
    h.truthy(out:find('v%.__tag == "Some"'))
    h.truthy(out:find('v%.__tag == "None"'))
  end)

  h.it("behavioral: Option round-trips", function()
    local mod = assert(compiler.eval(table.concat({
      "pub type Option = | Some { value } | None",
      "pub let unwrap opt fb = match opt with | Some { value } -> value | None -> fb",
      "pub let mk x = Some { value = x }",
      "pub let none = None",
    }, "\n")))
    h.eq(mod.unwrap(mod.mk(42), 0), 42)
    h.eq(mod.unwrap(mod.none, -1), -1)
  end)
  h.it("behavioral: Shape dispatch", function()
    local mod = assert(compiler.eval(table.concat({
      "type Shape = | Circle { radius } | Rect { width, height } | Origin",
      "pub let area s = match s with",
      "  | Circle { radius }       -> 3 * radius * radius",
      "  | Rect { width, height }  -> width * height",
      "  | Origin                  -> 0",
      "pub let c = Circle { radius = 2 }",
      "pub let r = Rect { width = 4, height = 3 }",
      "pub let o = Origin",
    }, "\n")))
    h.eq(mod.area(mod.c), 12); h.eq(mod.area(mod.r), 12); h.eq(mod.area(mod.o), 0)
  end)
  h.it("behavioral: recursive tree sum", function()
    local mod = assert(compiler.eval(table.concat({
      "type Tree = | Node { left, value, right } | Leaf",
      "pub let sum t = match t with",
      "  | Leaf -> 0",
      "  | Node { left, value, right } -> sum(left) + value + sum(right)",
      "pub let make = Node { left = Node { left = Leaf, value = 1, right = Leaf }, value = 2, right = Leaf }",
    }, "\n")))
    h.eq(mod.sum(mod.make), 3)
  end)
  h.it("behavioral: nested constructor pattern + guard", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let f v = match v with",
      "  | Some { value: [a, b] } when a > b -> a",
      "  | Some { value: [a, b] }            -> b",
      "  | _                                 -> 0",
    }, "\n")))
    h.eq(mod.f({ __tag = "Some", value = { 5, 2 } }), 5)
    h.eq(mod.f({ __tag = "Some", value = { 1, 9 } }), 9)
    h.eq(mod.f({ __tag = "None" }), 0)
  end)
  h.it("behavioral: __tag does not clash with a user field named tag", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let mk = Circle { tag = 9, radius = 1 }",
      "pub let r v = match v with | Circle { tag, radius } -> tag + radius | _ -> 0",
    }, "\n")))
    h.eq(mod.r(mod.mk), 10)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `codegen.expr` errors on `construct`; `type_decl` in `M.program` hits `M.expr` → "cannot emit expression of kind 'type_decl'"; the behavioral tests fail.

- [ ] **Step 3: Implement**

In `omelette/codegen.lua`, add the `construct` case in `expr` (immediately after the `table` case, near the other literals):
```lua
  if k == "construct" then
    local parts = { "__tag = " .. quote_string(node.tag) }
    for _, f in ipairs(node.fields) do parts[#parts + 1] = f.key .. " = " .. expr(f.value, ctx) end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
```

Add the `ctor_pat` branch in `compile_pattern` (alongside `record_pat`):
```lua
  elseif k == "ctor_pat" then
    tests[#tests + 1] = "type(" .. access .. ') == "table"'
    tests[#tests + 1] = access .. ".__tag == " .. quote_string(pat.tag)
    for _, f in ipairs(pat.fields) do
      compile_pattern(f.pat, access .. "." .. f.key, ctx, tests, binds)
    end
```

In `M.program`, skip `type_decl` in the emission loop — change the top of the per-node body from `if node.kind ~= "let" then … else …` to:
```lua
    if node.kind == "type_decl" then
      -- erased: a type declaration emits no runtime code
    elseif node.kind ~= "let" then
      lines[#lines + 1] = M.expr(node, ctx)
    else
      lines[#lines + 1] = gen_top_assign(node, ctx)
      if node.is_pub then
        lines[#lines + 1] = "M." .. node.name .. " = " .. node.name
      end
    end
```
(The forward-declaration `names` loop already only collects `let` names, so `type_decl` is correctly excluded there.)

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — golden + all behavioral sum-type tests green (Option, Shape, recursive tree, nested+guard, `__tag` non-clash); all prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add omelette/codegen.lua spec/sumtype_codegen_spec.lua
git commit -m "feat: codegen tagged-table construction + constructor patterns (type decl erased)"
```

---

### Task 3: Typecheck — non-crashing, no false positives

**Files:**
- Modify: `omelette/typecheck.lua` (skip `type_decl` in `check`; synth `construct`; handle `ctor_pat` in `collect_pattern_vars`)
- Create: `spec/sumtype_typecheck_spec.lua`

**Interfaces:**
- Consumes the Task 1 AST. Produces: no diagnostics from sum types (dynamic); construct field values are still walked; constructor-pattern-bound vars are `any`.

- [ ] **Step 1: Write the failing test**

`spec/sumtype_typecheck_spec.lua`:
```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local tc = require("omelette.typecheck")
local function diags(s) return tc.check(assert(parser.parse(s))) end

h.describe("sum type typecheck", function()
  h.it("no false positives for decls + construction + constructor patterns", function()
    h.eq(#diags(table.concat({
      "type Option = | Some { value } | None",
      "pub let unwrap opt fb = match opt with | Some { value } -> value | None -> fb",
      "pub let mk x = Some { value = x }",
    }, "\n")), 0)
  end)
  h.it("still catches a real mismatch elsewhere", function()
    local d = diags(table.concat({
      "type Option = | Some { value } | None",
      'let bad: number = "hi"',
    }, "\n"))
    h.truthy(#d >= 1)
    h.truthy(d[1].message:find("number", 1, true))
  end)
  h.it("walks construct field values (an error inside a field is caught)", function()
    local d = diags('let x = Some { value = 1 + "oops" }')
    h.truthy(#d >= 1)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `M.check` calls `synth` on the top-level `type_decl` (harmless `any`) but `synth` has no `construct` case (returns the catch-all `any` without walking fields, so the field-error test fails); `collect_pattern_vars` doesn't recurse `ctor_pat` (so pattern-bound vars used in an arm could mis-resolve). The field-error test and (if applicable) a binding test drive the change.

- [ ] **Step 3: Implement**

In `omelette/typecheck.lua`:

Add a `construct` case to `Checker:synth` (near the `table` case):
```lua
  if k == "construct" then
    for _, f in ipairs(node.fields) do self:synth(f.value, env) end
    return ANY
  end
```

Add `ctor_pat` to `collect_pattern_vars`:
```lua
  elseif k == "ctor_pat" then for _, f in ipairs(pat.fields) do collect_pattern_vars(f.pat, out) end
```

Skip `type_decl` in `M.check`'s pass-2 loop — change `else c:synth(node, genv)` to:
```lua
    elseif node.kind ~= "type_decl" then c:synth(node, genv)
```
(Pass 1 already only handles `let`, so `type_decl` is skipped there.)

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — sum-type typecheck tests green (no false positives; real mismatch caught; construct field error caught); all prior tests still green; stdlib still checks clean.

- [ ] **Step 5: Commit**

```bash
git add omelette/typecheck.lua spec/sumtype_typecheck_spec.lua
git commit -m "feat: typecheck synths construct fields, binds constructor-pattern vars, skips type decls"
```

---

## Self-Review

**1. Spec coverage:**
- `type` decl (named-field + nullary variants, `pub`, leading `|`, lowercase-ctor error) → Task 1. ✓
- Construction `Ctor { f = v }` / nullary via capitalization → Task 1 parse + Task 2 codegen. ✓
- Constructor patterns (fields, nullary, nested/rename) via capitalization → Task 1 + Task 2. ✓
- Runtime rep `{ __tag = … }`; `__tag` non-clash → Task 2 codegen + behavioral. ✓
- `type_decl` erased (emits nothing) → Task 2 golden + `M.program` skip. ✓
- Recursive types, dispatch, guards on ctor arms → Task 2 behavioral. ✓
- Typecheck: skip decl, synth construct fields, collect ctor_pat vars, no false positives → Task 3. ✓
- Deferred (typing/exhaustiveness, generics) → not implemented (correct). ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". Complete code + full test assertions in every step. Golden strings pinned to the exact emitted shape (`{ __tag = "Circle", radius = 5 }`).

**3. Type consistency:** The `type_decl`/`construct`/`ctor_pat` node shapes produced in Task 1 are exactly what Task 2 (`expr` construct, `compile_pattern` ctor_pat, `M.program` skip) and Task 3 (`synth` construct, `collect_pattern_vars` ctor_pat, `check` skip) consume. `construct.fields` use `{key, value}` (like record literals); `ctor_pat.fields` use `{key, pat}` (like record patterns) — consistent with the existing record handling they mirror. `quote_string` (a codegen local) is in scope in both `expr` and `compile_pattern`. ✓
