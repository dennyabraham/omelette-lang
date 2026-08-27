# Functional Record Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `{ base with field = v, … }` — a shallow copy of `base` with the listed fields overridden — to Omelette's immutable record surface.

**Architecture:** The `{`-handling parser block gains a `with` form: after the record-literal check fails, parse an expression, then branch on `with` (functional update) vs `=>` (dict comprehension). Codegen lowers the update to an inline IIFE that `pairs`-copies the base and applies overrides. No type-system change; output is readable Lua 5.1.

**Tech Stack:** Pure Lua (LuaJIT + Lua 5.4 in CI); `omelette.parser` / `omelette.codegen` / `omelette.compiler`; `spec/support/harness.lua`.

## Global Constraints

- Runs on both LuaJIT and Lua 5.4 (CI matrix).
- Codegen uses an inline IIFE — no injected runtime helper (dependency-free, byte-clean output).
- Shallow copy via `pairs`; the base is evaluated exactly once (as the IIFE argument); works on any table value (so it updates sum-type values and preserves `__tag`).
- `record_update` joins `PREFIX_NEEDS_PAREN` so a literal-base index/field/call stays valid Lua 5.1.
- Temp names `__base`, `__new`, `__k`, `__v` — following the existing IIFE-temp convention (`__acc`, `__m`, `__i`); user identifiers may start with `_` but the copy loop references nothing from user scope.
- `compiler.compile(src)` → `lua, nil` | `nil, err`; `compiler.eval(src)` → module table | `nil, err`. `parser.parse_expr_string(src)` → a single expression AST.
- Harness: `local h = require("spec.support.harness")`; `h.describe/it/eq/truthy`. Run: `luajit spec/run.lua`.

---

### Task 1: Parser — the `record_update` node

**Files:**
- Modify: `omelette/parser.lua` (the `{`-handling block in `parse_primary`, ~lines 237-244 — the dict-comprehension tail)
- Test: `spec/record_update_parser_spec.lua`

**Interfaces:**
- Consumes: `Parser:parse_expr()`, `Parser:at("keyword", "with")`, `Parser:expect`, `Parser:accept_comma()` (existing).
- Produces: `{ kind = "record_update", base = <expr>, fields = { { key = <string>, value = <expr> }, … }, line, col }` — consumed by Task 2's codegen. Dict comprehension is unchanged: `{ kind = "dict_comprehension", key, value, quals }`.

- [ ] **Step 1: Write the failing test**

Create `spec/record_update_parser_spec.lua`:

```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local function expr(s) return assert(parser.parse_expr_string(s)) end

h.describe("record update — parsing", function()
  h.it("parses `{ base with f = v }` as a record_update", function()
    local e = expr("{ c with radius = 5 }")
    h.eq(e.kind, "record_update")
    h.eq(e.base.kind, "ident")
    h.eq(e.base.name, "c")
    h.eq(#e.fields, 1)
    h.eq(e.fields[1].key, "radius")
    h.eq(e.fields[1].value.kind, "number")
    h.eq(e.fields[1].value.value, 5)
  end)
  h.it("parses multiple override fields", function()
    local e = expr("{ r with a = 1, b = 2 }")
    h.eq(e.kind, "record_update")
    h.eq(#e.fields, 2)
    h.eq(e.fields[2].key, "b")
  end)
  h.it("a non-ident base still parses (table literal base)", function()
    local e = expr("{ { a = 1 } with a = 2 }")
    h.eq(e.kind, "record_update")
    h.eq(e.base.kind, "table")
  end)
  h.it("a dict comprehension still parses (regression)", function()
    local e = expr("{ k => v | k, v <- m }")
    h.eq(e.kind, "dict_comprehension")
  end)
  h.it("a record literal still parses (regression)", function()
    local e = expr("{ x = 1 }")
    h.eq(e.kind, "table")
  end)
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit spec/run.lua 2>&1 | grep -iE "record update — parsing|fail" | head`
Expected: FAIL — `{ c with … }` currently reaches the dict-comprehension path and errors expecting `=>`.

- [ ] **Step 3: Implement the parser branch**

In `omelette/parser.lua`, replace the dict-comprehension tail of the `{`-block (the lines from `local key = self:parse_expr()` through the `dict_comprehension` return):

```lua
    -- dict comprehension: `key => value | quals`
    local key = self:parse_expr()
    self:expect("op", "=>")
    local value = self:parse_expr()
    self:expect("punct", "|")
    local quals = self:parse_qualifiers()
    self:expect("punct", "}")
    return { kind = "dict_comprehension", key = key, value = value, quals = quals, line = t.line, col = t.col }
```

with a version that first checks for a functional update:

```lua
    -- functional record update `expr with f = v, …`, or dict comprehension `key => value | quals`
    local head = self:parse_expr()
    if self:at("keyword", "with") then
      self:next()  -- consume `with`
      local fields = {}
      repeat
        local key = self:expect("ident").value
        self:expect("op", "=")
        local value = self:parse_expr()
        fields[#fields + 1] = { key = key, value = value }
      until not self:accept_comma()
      self:expect("punct", "}")
      return { kind = "record_update", base = head, fields = fields, line = t.line, col = t.col }
    end
    self:expect("op", "=>")
    local value = self:parse_expr()
    self:expect("punct", "|")
    local quals = self:parse_qualifiers()
    self:expect("punct", "}")
    return { kind = "dict_comprehension", key = head, value = value, quals = quals, line = t.line, col = t.col }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: full suite passes, 0 failures (new parser cases green).

- [ ] **Step 5: Commit**

```bash
git add omelette/parser.lua spec/record_update_parser_spec.lua
git commit -m "feat(parser): record_update node for { base with f = v }"
```

---

### Task 2: Codegen — IIFE lowering + tests + guide

**Files:**
- Modify: `omelette/codegen.lua` (add `record_update = true` to `PREFIX_NEEDS_PAREN`; add a `gen_record_update` helper and a `record_update` dispatch case)
- Test: `spec/record_update_spec.lua`
- Modify: `docs/guide.md` (one verified example)

**Interfaces:**
- Consumes: the `record_update` node from Task 1 (`node.base`, `node.fields[].key`, `node.fields[].value`); the forward-declared `expr` local; the `PREFIX_NEEDS_PAREN` table.
- Produces: emitted Lua for `record_update`.

- [ ] **Step 1: Write the failing tests**

Create `spec/record_update_spec.lua`:

```lua
local h = require("spec.support.harness")
local compiler = require("omelette.compiler")
local function eval(src) return assert(compiler.eval(src)) end

h.describe("functional record update", function()
  h.it("overrides a single field, leaves others", function()
    local m = eval("pub let base = { a = 1, b = 2 }\npub let out = { base with a = 9 }")
    h.eq(m.out.a, 9); h.eq(m.out.b, 2)
  end)
  h.it("leaves the original unchanged", function()
    local m = eval("pub let base = { a = 1, b = 2 }\npub let out = { base with a = 9 }")
    h.eq(m.base.a, 1)
  end)
  h.it("overrides multiple fields in order", function()
    local m = eval("pub let base = { a = 1, b = 2, c = 3 }\npub let out = { base with a = 9, c = 7 }")
    h.eq(m.out.a, 9); h.eq(m.out.b, 2); h.eq(m.out.c, 7)
  end)
  h.it("an override may reference the original", function()
    local m = eval("pub let pt = { x = 4 }\npub let out = { pt with x = pt.x + 1 }")
    h.eq(m.out.x, 5)
  end)
  h.it("updating a sum-type value preserves its tag", function()
    local m = eval([[
type Shape = | Circle { radius } | Origin
pub let c = Circle { radius = 3 }
pub let c2 = { c with radius = 9 }
pub let area = match c2 with | Circle { radius } -> radius * radius | Origin -> 0
]])
    h.eq(m.area, 81)
    h.eq(m.c2.__tag, "Circle")
  end)
  h.it("evaluates the base exactly once", function()
    local lua = assert(compiler.compile("pub let out = { mybaseident with x = 1 }"))
    local _, n = lua:gsub("mybaseident", "")
    h.eq(n, 1)
  end)
  h.it("a record-update literal composes as a field base", function()
    local m = eval("pub let base = { a = 1 }\npub let x = { base with a = 5 }.a")
    h.eq(m.x, 5)
  end)
  h.it("the emitted Lua loads", function()
    local lua = assert(compiler.compile("pub let out = { { a = 1 } with a = 2 }"))
    local load_fn = loadstring or load
    h.truthy((load_fn(lua)))
  end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `luajit spec/run.lua 2>&1 | grep -iE "functional record update|record_update|fail" | head`
Expected: FAIL — codegen has no `record_update` case, so `M.expr` errors ("cannot emit expression of kind 'record_update'").

- [ ] **Step 3: Add the codegen**

In `omelette/codegen.lua`:

(a) Add `record_update` to the `PREFIX_NEEDS_PAREN` set:

```lua
local PREFIX_NEEDS_PAREN = { array = true, table = true, string = true, lambda = true, construct = true, record_update = true }
```

(b) Add a `gen_record_update` helper alongside the other `gen_*` helpers (after the `prefix` helper and before `expr = function`), so it can reference the forward-declared `expr`:

```lua
-- { base with f = v, … } → copy the base (shallow) and override fields, via an inline IIFE
-- (no runtime helper injected). The base is emitted once, as the IIFE argument.
local function gen_record_update(node, ctx)
  local lines = {
    "(function(__base)",
    "  local __new = {}",
    "  for __k, __v in pairs(__base) do __new[__k] = __v end",
  }
  for _, f in ipairs(node.fields) do
    lines[#lines + 1] = "  __new." .. f.key .. " = " .. expr(f.value, ctx)
  end
  lines[#lines + 1] = "  return __new"
  lines[#lines + 1] = "end)(" .. expr(node.base, ctx) .. ")"
  return table.concat(lines, "\n")
end
```

(c) Add the dispatch case inside `expr` (near the `table` case ~line 231):

```lua
  if k == "record_update" then return gen_record_update(node, ctx) end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: full suite passes, 0 failures.

- [ ] **Step 5: Add a guide example and verify the doctest**

In `docs/guide.md`, in the pattern-matching / records area (after the `describe` record-pattern example that prints `diagonal`), add:

````markdown
Copy a record with some fields changed — the original is untouched:

```egg
let p = { x = 1, y = 2 }
print({ p with y = 9 }.y)
```
```output
9
```
````

Then run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: still 0 failures — the doctest harness compiled and ran the new example and matched its `output` (`9`).

- [ ] **Step 6: Commit**

```bash
git add omelette/codegen.lua spec/record_update_spec.lua docs/guide.md
git commit -m "feat(codegen): functional record update lowering ({ r with f = v })"
```

---

## Post-merge (not a plan task)

Update `docs/ROADMAP.md`: move "Functional record update" from Now/Next to the Shipped section.
