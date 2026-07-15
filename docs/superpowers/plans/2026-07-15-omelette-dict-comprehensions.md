# Omelette Dict Comprehensions & merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `{ key => value | quals }` dict comprehensions and use them for `std.table.merge`.

**Architecture:** Task 1 adds the `=>` token, a dict-comprehension branch in the parser's `{` case (with the comprehension qualifier parsing extracted into a shared `parse_qualifiers`), and a `dict_comprehension` codegen case that reuses a shared comprehension-IIFE helper (differing only in the innermost line: `acc[key] = value` vs list append). Task 2 adds `merge` to `std/table.egg`.

**Tech Stack:** Pure Lua compiler; module in Omelette; tested with the in-repo harness under `luajit`.

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline**. Test runner is `luajit spec/run.lua`.
- Separator is **`=>`** (new token). Record literals (`{ x = 1 }`) are unchanged.
- Record vs dict-comp: after `{`, `ident` immediately followed by `=` → record; anything else → dict comprehension.
- Dict comprehension requires ≥1 generator (shared with list comprehensions).
- Compiles to an IIFE (valid in any expression position), Lua 5.1-safe (`for … do`, `pairs`/`ipairs`, `#`).
- `merge(a, b)`: result has all keys of both; on a shared key, **`b` wins**. Self-contained in `std/table.egg` (no cross-module require).

---

## Data Structures (authoritative reference)

```lua
{ kind = "dict_comprehension", key = <expr>, value = <expr>, quals = { <qualifier>... }, line, col }
-- qualifier (shared): { kind = "generator", name, value_name=<string>|nil, source } | { kind = "guard", cond }
```

---

### Task 1: Dict comprehensions `{ key => value | quals }`

**Files:**
- Modify: `omelette/lexer.lua:12` (add `=>` to `MULTI_OPS`)
- Modify: `omelette/parser.lua` (add `Parser:parse_qualifiers`; use it in the `[` branch lines 151-179; rewrite the `{` branch)
- Modify: `omelette/codegen.lua` (factor a shared comprehension-IIFE helper; add `gen_dict_comprehension` + a `dict_comprehension` dispatch case)
- Create: `spec/dict_comprehension_spec.lua`

**Interfaces:**
- Consumes: `lexer.tokenize`, `parser.parse_expr_string`, `codegen.expr`/`new_ctx`, `compiler.eval`.
- Produces: `{ k => v | quals }` parses to a `dict_comprehension` node and compiles to an IIFE assigning `acc[key] = value`.

- [ ] **Step 1: Write the failing test**

`spec/dict_comprehension_spec.lua`:
```lua
local h = require("spec.support.harness")
local lexer = require("omelette.lexer")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function expr(s) return assert(parser.parse_expr_string(s)) end
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end

h.describe("dict comprehensions", function()
  h.it("lexes => as one op token", function()
    local toks = assert(lexer.tokenize("k => v"))
    h.eq(toks[2], { type = "op", value = "=>", line = 1, col = 3 })
  end)
  h.it("still lexes record `=` (not =>)", function()
    local toks = assert(lexer.tokenize("x = 1"))
    h.eq(toks[2], { type = "op", value = "=", line = 1, col = 3 })
  end)
  h.it("parses a dict comprehension", function()
    local e = expr("{ k => v | k, v <- d }")
    h.eq(e.kind, "dict_comprehension")
    h.eq(e.key.name, "k")
    h.eq(e.value.name, "v")
    h.eq(#e.quals, 1)
    h.eq(e.quals[1].kind, "generator")
    h.eq(e.quals[1].value_name, "v")
  end)
  h.it("still parses record literals (regression)", function()
    h.eq(expr("{ x = 1, y = 2 }").kind, "table")
    h.eq(expr("{}").kind, "table")
    h.eq(#expr("{}").fields, 0)
  end)
  h.it("emits an IIFE assigning acc[key] = value", function()
    h.eq(gen("{ k => v | k, v <- d }"),
      "(function()\n  local __acc1 = {}\n  for k, v in pairs(d) do\n"
      .. "    __acc1[k] = v\n  end\n  return __acc1\nend)()")
  end)
  h.it("behavioral: copy, map values, filter, and build-from-range", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let copy = { k => v | k, v <- { a = 1, b = 2 } }",
      "pub let scaled = { k => v * 10 | k, v <- { a = 1, b = 2 } }",
      "pub let big = { k => v | k, v <- { a = 1, b = 2, c = 3 }, v > 1 }",
      "pub let squares = { i => i * i | i <- [1 to 3] }",
    }, "\n")))
    h.eq(mod.copy, { a = 1, b = 2 })
    h.eq(mod.scaled, { a = 10, b = 20 })
    h.eq(mod.big, { b = 2, c = 3 })
    h.eq(mod.squares, { 1, 4, 9 })
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `=>` lexes as `=` then `>` (or unexpected), and the `dict_comprehension` assertions fail.

- [ ] **Step 3: Implement the lexer + parser + codegen**

**Lexer** — in `omelette/lexer.lua`, change line 12 to add `"=>"`:
```lua
local MULTI_OPS = { "|>", "->", "..", "==", "~=", "<=", ">=", "<-", "=>" }
```

**Parser** — in `omelette/parser.lua`, add a `Parser:parse_qualifiers` method (place it near the other `Parser:` methods, e.g. just before `Parser:parse_primary`):
```lua
-- parse a comprehension qualifier list (shared by list and dict comprehensions):
-- single generator `x <- src`, kv generator `k, v <- src`, or guard `<expr>`.
-- Requires at least one generator.
function Parser:parse_qualifiers()
  local quals, has_gen = {}, false
  repeat
    local cur, nxt = self:peek(), self:peek2()
    local t3, t4 = self.toks[self.pos + 2], self.toks[self.pos + 3]
    if cur.type == "ident" and nxt and nxt.type == "op" and nxt.value == "<-" then
      local name = self:next().value
      self:expect("op", "<-")
      local source = self:parse_expr()
      quals[#quals + 1] = { kind = "generator", name = name, value_name = nil, source = source }
      has_gen = true
    elseif cur.type == "ident" and nxt and nxt.type == "punct" and nxt.value == ","
        and t3 and t3.type == "ident" and t4 and t4.type == "op" and t4.value == "<-" then
      local name = self:next().value
      self:expect("punct", ",")
      local value_name = self:expect("ident").value
      self:expect("op", "<-")
      local source = self:parse_expr()
      quals[#quals + 1] = { kind = "generator", name = name, value_name = value_name, source = source }
      has_gen = true
    else
      local cond = self:parse_expr()
      quals[#quals + 1] = { kind = "guard", cond = cond }
    end
  until not self:accept_comma()
  if not has_gen then self:fail("comprehension needs at least one generator (name <- source)") end
  return quals
end
```

Replace the list-comprehension body in the `[` branch (currently lines 151-179 — the `if self:at("punct", "|") then … end` block) with the shared call:
```lua
    if self:at("punct", "|") then
      self:next()
      local quals = self:parse_qualifiers()
      self:expect("punct", "]")
      return { kind = "comprehension", yield = first, quals = quals, line = t.line, col = t.col }
    end
```

Replace the whole `{` branch of `parse_primary` (currently the record-only block) with:
```lua
  if self:at("punct", "{") then
    self:next()
    if self:at("punct", "}") then
      self:next()
      return { kind = "table", fields = {}, line = t.line, col = t.col }
    end
    -- record literal: `ident = …`; anything else is a dict comprehension
    if self:at("ident") and self:peek2() and self:peek2().type == "op" and self:peek2().value == "=" then
      local fields = {}
      repeat
        local key = self:expect("ident")
        self:expect("op", "=")
        local value = self:parse_expr()
        fields[#fields + 1] = { key = key.value, value = value }
      until not self:accept_comma()
      self:expect("punct", "}")
      return { kind = "table", fields = fields, line = t.line, col = t.col }
    end
    -- dict comprehension: `key => value | quals`
    local key = self:parse_expr()
    self:expect("op", "=>")
    local value = self:parse_expr()
    self:expect("punct", "|")
    local quals = self:parse_qualifiers()
    self:expect("punct", "}")
    return { kind = "dict_comprehension", key = key, value = value, quals = quals, line = t.line, col = t.col }
  end
```

**Codegen** — in `omelette/codegen.lua`, replace the existing `gen_comprehension` local function with a shared IIFE helper plus two thin wrappers:
```lua
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
```
(This keeps `gen_comprehension`'s output byte-identical for list comprehensions — the innermost line is exactly `acc .. "[#" .. acc .. " + 1] = " .. expr(node.yield, ctx)` as before.)

Add the dispatch in `expr`, immediately after the existing `comprehension` case:
```lua
  if k == "dict_comprehension" then return gen_dict_comprehension(node, ctx) end
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — dict-comprehension tests green (incl. the golden IIFE and behavioral cases); ALL prior tests still green (list-comprehension golden output is unchanged; record literals still parse).

- [ ] **Step 5: Commit**

```bash
git add omelette/lexer.lua omelette/parser.lua omelette/codegen.lua spec/dict_comprehension_spec.lua
git commit -m "feat: dict comprehensions { key => value | quals }"
```

---

### Task 2: `std.table.merge`

**Files:**
- Modify: `std/table.egg` (add `merge` + local helpers)
- Modify: `spec/table_spec.lua` (add a `merge` behavioral test)

**Interfaces:**
- Consumes: dict comprehensions (Task 1), the module's existing `keys`/`has`, indexing/length, list comprehensions, `[a to b]`.
- Produces: `merge(a, b) -> table` with all keys of both; `b` wins on shared keys.

- [ ] **Step 1: Write the failing test**

Add to `spec/table_spec.lua` inside the existing `describe` block:
```lua
  h.it("merge combines dicts, b wins on shared keys", function()
    h.eq(T.merge({ a = 1, b = 2 }, { b = 9, c = 3 }), { a = 1, b = 9, c = 3 })
    h.eq(T.merge({}, { x = 1 }), { x = 1 })
    h.eq(T.merge({ x = 1 }, {}), { x = 1 })
  end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `T.merge` is nil (`attempt to call ... a nil value`).

- [ ] **Step 3: Implement**

Append to `std/table.egg` (after the existing `keys`/`values`/`get`/`has`/`size`):
```
let pick a b k = if has(b, k) then b[k] else a[k]
let cc a b i = if i <= #a then a[i] else b[i - #a]
let allkeys a b = [ cc(a, b, i) | i <- [1 to (#a + #b)] ]
pub let merge a b = { k => pick(a, b, k) | k <- allkeys(keys(a), keys(b)) }
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — the `merge` test green; all prior tests green.

- [ ] **Step 5: Commit**

```bash
git add std/table.egg spec/table_spec.lua
git commit -m "feat: std.table.merge via dict comprehension"
```

---

## Self-Review

**1. Spec coverage:**
- `{ key => value | quals }` dict comprehension, `=>` token → Task 1 (lexer + parser + codegen). ✓
- Record vs dict-comp disambiguation (`ident =` → record, else dict comp); record regression → Task 1 parser + tests. ✓
- Shared `parse_qualifiers` (list + dict), ≥1 generator → Task 1. ✓
- Codegen IIFE assigning `acc[key] = value`; `pairs`/`ipairs` generators; list-comp output unchanged → Task 1 (shared `gen_comp_iife`). ✓
- Behavioral: copy / map values / filter / range-source → Task 1. ✓
- `merge` self-contained, b-wins, all keys → Task 2. ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". Complete code and full test assertions in every step. The golden IIFE string is traced against `gen_dict_comprehension` (`{ k => v | k, v <- d }` → the shown string). ✓

**3. Type consistency:** `dict_comprehension` uses `key`/`value`/`quals` in both parser (producer) and codegen (`gen_dict_comprehension`, consumer). `parse_qualifiers` returns the same `quals` shape the `[` branch used before (generator with `name`/`value_name`/`source`, guard with `cond`). `gen_comp_iife`'s `inner(acc)` contract is used identically by both `gen_comprehension` and `gen_dict_comprehension`. `merge` uses the module's existing `keys`/`has` (defined above it) and the local helpers defined before it. ✓
