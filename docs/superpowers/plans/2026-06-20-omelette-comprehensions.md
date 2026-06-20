# Omelette List Comprehensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Haskell-style list comprehensions `[ yield | qualifiers ]` (multiple generators + guards) to Omelette, compiling each to an IIFE so it works in any expression position.

**Architecture:** Three additive changes to the existing pipeline: a new `<-` lexer token, a comprehension branch in the parser's `[` case (producing new `comprehension`/`generator`/`guard` AST nodes), and a `comprehension` case in `codegen.expr` that emits a self-contained immediately-invoked function expression with nested `for`/`if` over `ipairs`. No changes to compiler/resolver/CLI/REPL/searcher.

**Tech Stack:** Pure Lua compiler, tested with the in-repo harness under `luajit`.

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline** (no `//`, no native bitops, no `goto`, no `<close>`). Test runner is `luajit spec/run.lua`.
- AST nodes are **plain tables tagged with a `kind` string**, carrying `line`/`col`.
- Errors are **returned as values** (a diagnostic), never raised, on user-facing failure paths. The parser signals errors via `self:fail(...)`.
- The only new lexer token is **`<-`** (type `op`, value `"<-"`). **No new keywords.**
- A comprehension requires **at least one generator**; otherwise a diagnostic.
- Generator `source` is iterated by **value via `ipairs`**; the result is a **new array**; surface stays immutable (mutation hidden in generated Lua).
- Each comprehension compiles to an **IIFE** handled in `codegen.expr` (valid in any expression position).

---

## Data Structures (authoritative reference)

New AST nodes produced by Task 2, consumed by Task 3:
```lua
{ kind = "comprehension", yield = <expr-node>, quals = { <qualifier>... }, line, col }
-- qualifier is one of:
{ kind = "generator", name = <string>, source = <expr-node> }
{ kind = "guard", cond = <expr-node> }
```

Existing nodes the tasks rely on (unchanged): `array` (`{ kind="array", items={...} }`), `binop`, `ident`, `number`, `call`, `field`, `pipe`.

---

### Task 1: Lexer — the `<-` operator

**Files:**
- Modify: `omelette/lexer.lua:12`
- Create: `spec/comprehension_lexer_spec.lua`

**Interfaces:**
- Consumes: existing `lexer.tokenize(source) -> tokens, err`.
- Produces: `<-` lexes as a single token `{ type = "op", value = "<-" }`. `x < -1` (with spaces) still lexes as three tokens `<`, `-`, `1`.

- [ ] **Step 1: Write the failing test**

`spec/comprehension_lexer_spec.lua`:
```lua
local h = require("spec.support.harness")
local lexer = require("omelette.lexer")

local function types_and_values(src)
  local toks = assert(lexer.tokenize(src))
  local out = {}
  for _, t in ipairs(toks) do out[#out + 1] = { t.type, t.value } end
  return out
end

h.describe("lexer/arrow", function()
  h.it("lexes <- as a single op token", function()
    local toks = assert(lexer.tokenize("x <- xs"))
    h.eq(toks[1], { type = "ident", value = "x", line = 1, col = 1 })
    h.eq(toks[2], { type = "op", value = "<-", line = 1, col = 3 })
    h.eq(toks[3].value, "xs")
  end)
  h.it("lexes adjacent x<-1 greedily as the binder, not less-than-negative", function()
    local toks = assert(lexer.tokenize("x<-1"))
    h.eq(toks[2], { type = "op", value = "<-", line = 1, col = 2 })
  end)
  h.it("keeps spaced x < -1 as three tokens", function()
    h.eq(types_and_values("x < -1"),
      { { "ident", "x" }, { "op", "<" }, { "op", "-" }, { "number", 1 }, { "eof", "<eof>" } })
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `x <- xs` lexes `<` and `-` as two separate ops, so `toks[2]` is `{op,"<"}` not `{op,"<-"}`.

- [ ] **Step 3: Implement**

In `omelette/lexer.lua`, change line 12 from:
```lua
local MULTI_OPS = { "|>", "->", "..", "==", "~=", "<=", ">=" }
```
to:
```lua
local MULTI_OPS = { "|>", "->", "..", "==", "~=", "<=", ">=", "<-" }
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — arrow tests green, all prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add omelette/lexer.lua spec/comprehension_lexer_spec.lua
git commit -m "feat: lex <- operator for comprehensions"
```

---

### Task 2: Parser — comprehension syntax

**Files:**
- Modify: `omelette/parser.lua` (add `Parser:peek2`; rewrite the `[` case in `parse_primary`, currently lines 131–139)
- Create: `spec/comprehension_parser_spec.lua`

**Interfaces:**
- Consumes: `parser.parse_expr_string(source) -> expr_node, err`, the existing `Parser` methods (`peek`, `next`, `at`, `expect`, `accept_comma`, `parse_expr`, `fail`).
- Produces: the `comprehension`/`generator`/`guard` AST nodes (see Data Structures). Array-literal parsing is preserved unchanged for `[]`, `[a]`, `[a, b, c]`.

- [ ] **Step 1: Write the failing test**

`spec/comprehension_parser_spec.lua`:
```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local function expr(s) return assert(parser.parse_expr_string(s)) end

h.describe("parser/comprehension", function()
  h.it("still parses array literals (regression)", function()
    h.eq(expr("[1, 2, 3]").kind, "array")
    h.eq(#expr("[1, 2, 3]").items, 3)
    h.eq(expr("[]").kind, "array")
    h.eq(#expr("[]").items, 0)
    h.eq(expr("[7]").items[1].value, 7)
  end)
  h.it("parses a single-generator comprehension", function()
    local e = expr("[ x * 2 | x <- nums ]")
    h.eq(e.kind, "comprehension")
    h.eq(e.yield.kind, "binop")
    h.eq(#e.quals, 1)
    h.eq(e.quals[1], { kind = "generator", name = "x", source = e.quals[1].source })
    h.eq(e.quals[1].source.name, "nums")
  end)
  h.it("parses a guard after a generator", function()
    local e = expr("[ x | x <- xs, x > 0 ]")
    h.eq(#e.quals, 2)
    h.eq(e.quals[1].kind, "generator")
    h.eq(e.quals[2].kind, "guard")
    h.eq(e.quals[2].cond.kind, "binop")
  end)
  h.it("parses multiple generators and interleaved guards in order", function()
    local e = expr("[ [x, y] | x <- xs, x > 0, y <- ys ]")
    h.eq(e.yield.kind, "array")
    h.eq(#e.quals, 3)
    h.eq(e.quals[1].kind, "generator"); h.eq(e.quals[1].name, "x")
    h.eq(e.quals[2].kind, "guard")
    h.eq(e.quals[3].kind, "generator"); h.eq(e.quals[3].name, "y")
  end)
  h.it("treats a function-call qualifier as a guard, not a generator", function()
    local e = expr("[ x | x <- xs, even(x) ]")
    h.eq(e.quals[2].kind, "guard")
    h.eq(e.quals[2].cond.kind, "call")
  end)
  h.it("rejects a comprehension with no generator", function()
    local _, err = parser.parse_expr_string("[ x | x > 0 ]")
    h.truthy(err ~= nil)
    h.truthy(err.message:find("generator"))
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — comprehension input currently parses `x * 2` then hits `|` and errors (or mis-parses); `kind == "comprehension"` assertions fail.

- [ ] **Step 3: Implement**

In `omelette/parser.lua`, add a two-token lookahead helper next to `Parser:accept_comma` (after line 110):
```lua
function Parser:peek2() return self.toks[self.pos + 1] end
```

Then replace the `[` case in `parse_primary` (currently lines 131–139):
```lua
  if self:at("punct", "[") then
    self:next()
    if self:at("punct", "]") then
      self:next()
      return { kind = "array", items = {}, line = t.line, col = t.col }
    end
    local first = self:parse_expr()
    if self:at("punct", "|") then
      self:next()
      local quals, has_gen = {}, false
      repeat
        local cur, nxt = self:peek(), self:peek2()
        if cur.type == "ident" and nxt and nxt.type == "op" and nxt.value == "<-" then
          local name = self:next().value
          self:expect("op", "<-")
          local source = self:parse_expr()
          quals[#quals + 1] = { kind = "generator", name = name, source = source }
          has_gen = true
        else
          local cond = self:parse_expr()
          quals[#quals + 1] = { kind = "guard", cond = cond }
        end
      until not self:accept_comma()
      if not has_gen then self:fail("comprehension needs at least one generator (name <- source)") end
      self:expect("punct", "]")
      return { kind = "comprehension", yield = first, quals = quals, line = t.line, col = t.col }
    end
    local items = { first }
    while self:accept_comma() do
      items[#items + 1] = self:parse_expr()
    end
    self:expect("punct", "]")
    return { kind = "array", items = items, line = t.line, col = t.col }
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — comprehension parser tests green; the existing array/parser tests still green.

- [ ] **Step 5: Commit**

```bash
git add omelette/parser.lua spec/comprehension_parser_spec.lua
git commit -m "feat: parse list comprehensions with generators and guards"
```

---

### Task 3: Codegen — IIFE emission + behavioral verification

**Files:**
- Modify: `omelette/codegen.lua` (add `gen_comprehension` local + a `comprehension` case in `expr`)
- Create: `spec/comprehension_codegen_spec.lua` (golden strings)
- Create: `spec/comprehension_behavioral_spec.lua` (compile + run)

**Interfaces:**
- Consumes: comprehension AST (Task 2), existing `expr`/`gen_call`, `codegen.new_ctx`, `compiler.compile`/`compiler.eval`.
- Produces: `codegen.expr` emits an IIFE for `comprehension` nodes. The accumulator name is `__acc<n>` where `<n>` comes from a per-`ctx` counter `ctx.acc` (defaulting to 0), so multiple comprehensions in one module get distinct names.

- [ ] **Step 1: Write the failing golden test**

`spec/comprehension_codegen_spec.lua`:
```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local function gen(s)
  local e = assert(parser.parse_expr_string(s))
  return codegen.expr(e, codegen.new_ctx())
end

h.describe("codegen/comprehension", function()
  h.it("emits an IIFE for a single generator", function()
    h.eq(gen("[ x * 2 | x <- nums ]"),
      "(function()\n  local __acc1 = {}\n  for _, x in ipairs(nums) do\n"
      .. "    __acc1[#__acc1 + 1] = (x * 2)\n  end\n  return __acc1\nend)()")
  end)
  h.it("emits a guard as a nested if", function()
    h.eq(gen("[ x | x <- nums, even(x) ]"),
      "(function()\n  local __acc1 = {}\n  for _, x in ipairs(nums) do\n"
      .. "    if even(x) then\n      __acc1[#__acc1 + 1] = x\n    end\n  end\n"
      .. "  return __acc1\nend)()")
  end)
  h.it("nests multiple generators with an interleaved guard", function()
    h.eq(gen("[ [x, y] | x <- xs, x > 0, y <- ys ]"),
      "(function()\n  local __acc1 = {}\n  for _, x in ipairs(xs) do\n"
      .. "    if (x > 0) then\n      for _, y in ipairs(ys) do\n"
      .. "        __acc1[#__acc1 + 1] = {x, y}\n      end\n    end\n  end\n"
      .. "  return __acc1\nend)()")
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `codegen.expr` reaches its final `error("codegen: cannot emit expression of kind 'comprehension'")`.

- [ ] **Step 3: Implement the codegen**

In `omelette/codegen.lua`, add `gen_comprehension` as a local function immediately after `gen_pipe` (after line 58, before `expr = function(node, ctx)`):
```lua
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
      lines[#lines + 1] = pad .. "for _, " .. q.name .. " in ipairs(" .. expr(q.source, ctx) .. ") do"
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
```

Then add the dispatch case in `expr`, immediately before the final `error(...)` line (currently line 94):
```lua
  if k == "comprehension" then return gen_comprehension(node, ctx) end
```

- [ ] **Step 4: Run to verify the golden test passes**

Run: `luajit spec/run.lua`
Expected: PASS — the three golden comprehension tests green, all prior green.

- [ ] **Step 5: Write the behavioral test**

`spec/comprehension_behavioral_spec.lua`:
```lua
local h = require("spec.support.harness")
local compiler = require("omelette.compiler")

h.describe("comprehension/behavioral", function()
  h.it("maps over a list", function()
    local mod = assert(compiler.eval("pub let r = [ x * 2 | x <- [1, 2, 3] ]"))
    h.eq(mod.r, { 2, 4, 6 })
  end)
  h.it("filters with a guard", function()
    local mod = assert(compiler.eval(
      "let even x = x % 2 == 0\npub let r = [ x | x <- [1, 2, 3, 4], even(x) ]"))
    h.eq(mod.r, { 2, 4 })
  end)
  h.it("produces a cartesian product from two generators (x outer)", function()
    local mod = assert(compiler.eval("pub let r = [ [x, y] | x <- [1, 2], y <- [3, 4] ]"))
    h.eq(mod.r, { { 1, 3 }, { 1, 4 }, { 2, 3 }, { 2, 4 } })
  end)
  h.it("applies interleaved guards that reference earlier generators", function()
    local mod = assert(compiler.eval(
      "pub let r = [ [x, y] | x <- [1, 2, 3], x > 1, y <- [10, 20], x + y < 22 ]"))
    h.eq(mod.r, { { 2, 10 }, { 3, 10 } })
  end)
  h.it("works inline as a call argument (proves the IIFE)", function()
    local mod = assert(compiler.eval(
      'pub let s = table.concat([ x * 2 | x <- [1, 2, 3] ], ",")'))
    h.eq(mod.s, "2,4,6")
  end)
  h.it("works as the left side of a pipe", function()
    local mod = assert(compiler.eval(
      'pub let s = [ x * 2 | x <- [1, 2, 3] ] |> table.concat(",")'))
    h.eq(mod.s, "2,4,6")
  end)
  h.it("nests comprehensions (distinct accumulators)", function()
    local mod = assert(compiler.eval(
      "pub let r = [ [ y * 10 | y <- row ] | row <- [[1, 2], [3]] ]"))
    h.eq(mod.r, { { 10, 20 }, { 30 } })
  end)
end)
```

- [ ] **Step 6: Run to verify the behavioral test passes**

Run: `luajit spec/run.lua`
Expected: PASS — all 7 behavioral tests green (the falsy-safe runtime confirms map, filter, cartesian, interleaved guards, inline-arg, pipe, and nesting), all prior tests green.

- [ ] **Step 7: Commit**

```bash
git add omelette/codegen.lua spec/comprehension_codegen_spec.lua spec/comprehension_behavioral_spec.lua
git commit -m "feat: compile list comprehensions to IIFEs"
```

---

## Self-Review

**1. Spec coverage:**
- `[ yield | quals ]` with generators + guards → Tasks 2 (parse) + 3 (codegen). ✓
- Multiple generators nest left-to-right (x outer) → Task 3 golden + behavioral cartesian test. ✓
- Guards filter at position, see left-bound vars → Task 3 interleaved-guard behavioral test. ✓
- `<-` new token, no new keywords → Task 1. ✓
- Comprehension requires ≥1 generator → Task 2 reject test. ✓
- Iterate array values via `ipairs`; result is a new array → Task 3 codegen + behavioral. ✓
- Usable in any expression position (IIFE) → Task 3 inline-arg and pipe behavioral tests. ✓
- No tuples → pairs as `[x, y]` → used throughout Task 3 tests. ✓
- `[` disambiguation (singleton/array/comprehension) + regression → Task 2 regression test. ✓
- 5.1-safe codegen (`ipairs`, `#`, function expr, `for`) → Task 3. ✓
- Lexer `x < -1` spacing case → Task 1. ✓
- Errors as values (no-generator diagnostic) → Task 2. ✓
- Nested comprehensions with distinct `__acc<n>` → Task 3 nesting test. ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO"/"implement later". Every code step shows complete code; every test shows full assertions. ✓

**3. Type consistency:** AST field names (`yield`, `quals`, `name`, `source`, `cond`, `kind`) are identical across Task 2 (producer) and Task 3 (consumer). The accumulator counter `ctx.acc` is introduced and read only in Task 3's `gen_comprehension`. `Parser:peek2` is defined in Task 2 before use. Golden-string indentation in Task 3 Step 1 matches the `gen_comprehension` algorithm in Step 3 (verified by tracing `[ x * 2 | x <- nums ]`). ✓
