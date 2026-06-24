# Omelette Range Literals & Key/Value Generators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `[a to b]` range literals and two-name (`k, v <- dict`) comprehension generators to Omelette.

**Architecture:** Two additive changes to the existing pipeline. Range: a `to` keyword, a `range` branch in the `[` case of `parse_primary`, and a `range` IIFE in codegen. Key/value generators: extend the comprehension qualifier parser to detect `ident , ident <-`, and emit `pairs(...)` vs `ipairs(...)` based on a new optional `value_name` field. No changes to compiler/resolver/CLI/REPL/searcher.

**Tech Stack:** Pure Lua compiler, tested with the in-repo harness under `luajit`.

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline** (no `//`, no native bitops, no `goto`, no `<close>`). Test runner is `luajit spec/run.lua`.
- AST nodes are **plain tables tagged with a `kind` string**, carrying `line`/`col`.
- Range `[a to b]` is **inclusive, ascending, step 1**; `a > b` → empty (Lua numeric `for`).
- A comprehension generator binds **one name** (array values, `ipairs`) or **two names** (table pairs, `pairs`).
- Range and comprehensions compile to **IIFEs** (valid in any expression position) and stay Lua 5.1-safe (`for … do`, `ipairs`, `pairs`, `#`).

---

## Data Structures (authoritative reference)

```lua
{ kind = "range", from = <expr>, to = <expr>, line, col }                     -- new (Task 1)
-- comprehension generator gains an optional second name (Task 2):
{ kind = "generator", name = <string>, value_name = <string>|nil, source = <expr> }
```

Existing relevant code: the `[` branch of `parse_primary` (parser.lua:138-171) currently dispatches `]`→array, `,`→array, `|`→comprehension; the comprehension qualifier loop (parser.lua:148-160) detects single-name generators; `gen_comprehension` (codegen.lua:64-85) emits `for _, name in ipairs(...)`.

---

### Task 1: Range literal `[a to b]`

**Files:**
- Modify: `omelette/lexer.lua` (add `to` to the `KEYWORDS` table)
- Modify: `omelette/parser.lua:144-145` (range branch in the `[` case, after `first` is parsed)
- Modify: `omelette/codegen.lua` (add `gen_range` near `gen_comprehension`; add a `range` case in `expr`)
- Create: `spec/range_spec.lua`

**Interfaces:**
- Consumes: existing `lexer.tokenize`, `parser.parse_expr_string`, `codegen.expr`/`new_ctx`, `compiler.eval`.
- Produces: `[a to b]` parses to `{kind="range", from, to}` and compiles to an IIFE building `{a..b}`.

- [ ] **Step 1: Write the failing test**

`spec/range_spec.lua`:
```lua
local h = require("spec.support.harness")
local lexer = require("omelette.lexer")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function expr(s) return assert(parser.parse_expr_string(s)) end
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end

h.describe("range literals", function()
  h.it("lexes `to` as a keyword", function()
    local toks = assert(lexer.tokenize("1 to 5"))
    h.eq(toks[2], { type = "keyword", value = "to", line = 1, col = 3 })
  end)
  h.it("parses [a to b] as a range node", function()
    local e = expr("[1 to 5]")
    h.eq(e.kind, "range")
    h.eq(e.from.value, 1)
    h.eq(e.to.value, 5)
  end)
  h.it("still parses arrays and comprehensions (regression)", function()
    h.eq(expr("[1, 2, 3]").kind, "array")
    h.eq(expr("[]").kind, "array")
    h.eq(expr("[ x | x <- xs ]").kind, "comprehension")
  end)
  h.it("emits an IIFE with a numeric for", function()
    h.eq(gen("[1 to 5]"),
      "(function()\n  local __acc1 = {}\n  for __i = 1, 5 do\n"
      .. "    __acc1[#__acc1 + 1] = __i\n  end\n  return __acc1\nend)()")
  end)
  h.it("behavioral: inclusive ascending, empty when from > to", function()
    local mod = assert(compiler.eval("pub let a = [1 to 5]\npub let b = [5 to 1]"))
    h.eq(mod.a, { 1, 2, 3, 4, 5 })
    h.eq(mod.b, {})
  end)
  h.it("behavioral: range feeds a comprehension", function()
    local mod = assert(compiler.eval("pub let squares = [ x * x | x <- [1 to 3] ]"))
    h.eq(mod.squares, { 1, 4, 9 })
  end)
  h.it("behavioral: reverse via range + indexing", function()
    local mod = assert(compiler.eval(table.concat({
      "let reverse xs = [ xs[#xs - i + 1] | i <- [1 to #xs] ]",
      "pub let r = reverse([10, 20, 30])",
    }, "\n")))
    h.eq(mod.r, { 30, 20, 10 })
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `to` is lexed as an ident (not keyword), so `[1 to 5]` mis-parses (the `range` node assertions fail).

- [ ] **Step 3: Implement**

In `omelette/lexer.lua`, add `["to"]=true` to the `KEYWORDS` table (the table near the top listing `let`, `pub`, `fn`, `if`, `then`, `else`, `match`, `with`, `true`, `false`, `nil`, `and`, `or`, `not`, `lua`).

In `omelette/parser.lua`, insert a range branch immediately after `local first = self:parse_expr()` (line 144) and before the `if self:at("punct", "|")` comprehension check (line 145):
```lua
    if self:at("keyword", "to") then
      self:next()
      local to_expr = self:parse_expr()
      self:expect("punct", "]")
      return { kind = "range", from = first, to = to_expr, line = t.line, col = t.col }
    end
```

In `omelette/codegen.lua`, add `gen_range` immediately after `gen_comprehension` (after line 85, before `expr = function(node, ctx)`):
```lua
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
```
Add the dispatch in `expr`, immediately after the `comprehension` case (`if k == "comprehension" then ...`, codegen.lua:121):
```lua
  if k == "range" then return gen_range(node, ctx) end
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — range tests green, all prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add omelette/lexer.lua omelette/parser.lua omelette/codegen.lua spec/range_spec.lua
git commit -m "feat: add [a to b] range literals"
```

---

### Task 2: Key/value comprehension generators `k, v <- dict`

**Files:**
- Modify: `omelette/parser.lua:148-160` (two-name generator detection in the comprehension qualifier loop)
- Modify: `omelette/codegen.lua:70-74` (the generator emission in `gen_comprehension`)
- Create: `spec/kv_generator_spec.lua`

**Interfaces:**
- Consumes: the comprehension machinery from the comprehensions cycle.
- Produces: a generator node with `value_name` set for the two-name form; codegen emits `pairs` for two names, `ipairs` for one.

**Note on a deliberate ambiguity resolution:** `[ x | a, b <- xs ]` is resolved as a *two-name generator* `a, b <- xs` (the intended use), not as a bare-identifier guard `a` followed by generator `b <- xs`. Bare-identifier guards are unusual (guards are normally comparisons/calls); if one must precede a generator, reorder or wrap it. This is the natural consequence of the `k, v <-` syntax.

- [ ] **Step 1: Write the failing test**

`spec/kv_generator_spec.lua`:
```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function expr(s) return assert(parser.parse_expr_string(s)) end
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end

h.describe("key/value comprehension generators", function()
  h.it("parses a two-name generator", function()
    local e = expr("[ k | k, v <- d ]")
    h.eq(e.kind, "comprehension")
    h.eq(e.quals[1].kind, "generator")
    h.eq(e.quals[1].name, "k")
    h.eq(e.quals[1].value_name, "v")
    h.eq(e.quals[1].source.name, "d")
  end)
  h.it("leaves single-name generators with value_name = nil", function()
    local e = expr("[ x | x <- xs ]")
    h.eq(e.quals[1].name, "x")
    h.eq(e.quals[1].value_name, nil)
  end)
  h.it("emits pairs(...) for two names and ipairs(...) for one", function()
    h.truthy(gen("[ k | k, v <- d ]"):find("for k, v in pairs%(d%) do"))
    h.truthy(gen("[ x | x <- xs ]"):find("for _, x in ipairs%(xs%) do"))
  end)
  h.it("behavioral: keys and values of a record", function()
    local mod = assert(compiler.eval(table.concat({
      'pub let ks = [ k | k, v <- { a = 1, b = 2 } ]',
      'pub let vs = [ v | k, v <- { a = 1, b = 2 } ]',
    }, "\n")))
    table.sort(mod.ks)
    table.sort(mod.vs)
    h.eq(mod.ks, { "a", "b" })   -- pairs order is unspecified; sort to compare
    h.eq(mod.vs, { 1, 2 })
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `[ k | k, v <- d ]` currently parses `k` as a single-name generator, then `accept_comma` consumes `,`, then tries to parse `v <- d` as the next qualifier and `<- d` is unexpected — so it errors (or `value_name` is nil and the assertions fail).

- [ ] **Step 3: Implement**

In `omelette/parser.lua`, replace the comprehension qualifier loop body (lines 148-160) so generator detection handles both one and two names:
```lua
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
```

In `omelette/codegen.lua`, replace the generator branch in `gen_comprehension` (lines 70-71) to choose `pairs`/`ipairs`:
```lua
    if q.kind == "generator" then
      if q.value_name then
        lines[#lines + 1] = pad .. "for " .. q.name .. ", " .. q.value_name
          .. " in pairs(" .. expr(q.source, ctx) .. ") do"
      else
        lines[#lines + 1] = pad .. "for _, " .. q.name
          .. " in ipairs(" .. expr(q.source, ctx) .. ") do"
      end
    else
```
(Keep the `else` guard branch and the rest of `gen_comprehension` unchanged.)

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — key/value generator tests green; all prior comprehension/range tests still green.

- [ ] **Step 5: Commit**

```bash
git add omelette/parser.lua omelette/codegen.lua spec/kv_generator_spec.lua
git commit -m "feat: add key/value comprehension generators (k, v <- dict)"
```

---

## Self-Review

**1. Spec coverage:**
- `[a to b]` inclusive ascending, empty when `a > b` → Task 1 (lexer `to`, parser range, codegen IIFE, behavioral). ✓
- Range feeds a comprehension; reverse via range + indexing → Task 1 behavioral. ✓
- `[` dispatch still yields array/comprehension (regression) → Task 1 parser test. ✓
- `k, v <- dict` two-name generator → `pairs`; one name → `ipairs` → Task 2 (parser + codegen + behavioral keys/values). ✓
- `value_name = nil` for single-name → Task 2 parser test. ✓
- Lua 5.1-safe (`for`, `ipairs`, `pairs`, `#`) → Tasks 1/2. ✓
- Ambiguity resolution (`a, b <- xs` = two-name generator) → documented in Task 2 note. ✓
- Deferred (descending/step, merge/map-comprehensions) → not implemented (correct). ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". Each code step shows complete code; the `reverse` behavioral test is self-contained (defines `reverse` then calls it on a literal). ✓

**3. Type consistency:** `range` node uses `from`/`to` in both Task 1's parser and codegen. The generator node's new `value_name` field is written by Task 2's parser and read by Task 2's codegen; single-name generators set it to `nil`, which the codegen treats as the `ipairs` case. The range IIFE reuses `ctx.acc` (same counter as comprehensions) and a fixed `__i` loop var (safe — own function scope). The golden range string in Task 1 Step 1 matches `gen_range` in Step 3 (verified by tracing `[1 to 5]`). ✓
