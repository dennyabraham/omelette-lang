# Omelette `if` as a First-Class Expression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a parenthesized `(if c then a else b)` usable as a value sub-expression by emitting a `gen_if` IIFE from `codegen.expr`, keeping the existing non-closure `if` lowering for the common binding/branch/return positions.

**Architecture:** Purely additive to `omelette/codegen.lua`: a `gen_if` local (an IIFE that returns from each branch via the existing `gen_fn_body`) plus an `if k == "if"` dispatch in `expr`. `gen_value` and `gen_fn_body`'s existing `if` handling are NOT touched, so the common cases keep their clean output.

**Tech Stack:** Pure Lua compiler, tested with the in-repo harness under `luajit`.

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline**. Test runner is `luajit spec/run.lua`.
- The IIFE is falsy-safe (returns the value from each branch). Only a genuine sub-expression `if` (reached via `M.expr`) becomes an IIFE; `if` in binding/branch/return position keeps its non-closure lowering.
- `gen_value` and `gen_fn_body` are NOT modified.

---

### Task 1: `gen_if` IIFE + `expr` dispatch

**Files:**
- Modify: `omelette/codegen.lua` (add `gen_if` near `gen_match`; add the `if` case to `expr`)
- Create: `spec/if_expression_spec.lua`

**Interfaces:**
- Consumes: existing `expr`, `gen_fn_body`.
- Produces: `codegen.expr` emits an IIFE for `if` nodes; `gen_value`/`gen_fn_body` unchanged.

- [ ] **Step 1: Write the failing test**

`spec/if_expression_spec.lua`:
```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end
local function prog(s) return codegen.program(assert(parser.parse(s))) end

h.describe("if as expression", function()
  h.it("emits an IIFE returning from each branch", function()
    local out = gen("(if c then 1 else 2)")
    h.truthy(out:find("^%(function%(%)"))
    h.truthy(out:find("if c then"))
    h.truthy(out:find("return 1"))
    h.truthy(out:find("return 2"))
    h.truthy(out:find("end%)%(%)$"))
  end)
  h.it("regression: a let-bound if stays non-closure (statement lowering)", function()
    local out = prog("pub let f c = if c then 1 else 2")
    h.truthy(not out:find("%(function%(%)"))   -- no IIFE for the common case
    h.truthy(out:find("if c then"))
  end)

  h.it("behavioral: if as a binop operand", function()
    local mod = assert(compiler.eval("pub let f n = 1 + (if n > 0 then 10 else 20)"))
    h.eq(mod.f(5), 11); h.eq(mod.f(-1), 21)
  end)
  h.it("behavioral: if as a pipe LHS", function()
    local mod = assert(compiler.eval("pub let f c = (if c then 1 else 2) |> tostring"))
    h.eq(mod.f(true), "1"); h.eq(mod.f(false), "2")
  end)
  h.it("behavioral: if as a comprehension yield", function()
    local mod = assert(compiler.eval('pub let f xs = [ (if x > 0 then "p" else "n") | x <- xs ]'))
    h.eq(mod.f({ 1, -1, 2 }), { "p", "n", "p" })
  end)
  h.it("behavioral: if as a call argument (parenthesized)", function()
    local mod = assert(compiler.eval("pub let f c = tostring(if c then 1 else 2)"))
    h.eq(mod.f(true), "1")
  end)
  h.it("behavioral: falsy-safe", function()
    local mod = assert(compiler.eval("pub let f c = (if c then false else true)"))
    h.eq(mod.f(true), false); h.eq(mod.f(false), true)
  end)
  h.it("behavioral: nested if-expressions", function()
    local mod = assert(compiler.eval("pub let f a b = (if a then (if b then 1 else 2) else 3)"))
    h.eq(mod.f(true, true), 1); h.eq(mod.f(true, false), 2); h.eq(mod.f(false, false), 3)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `codegen.expr` errors on `if` ("cannot emit expression of kind 'if'"); the IIFE golden and behavioral tests fail.

- [ ] **Step 3: Implement**

In `omelette/codegen.lua`, add `gen_if` immediately before `gen_match` (they sit near `gen_comprehension`/`gen_range`, before `expr = function(node, ctx)`):
```lua
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
```

Add the dispatch in `expr`, immediately before the existing `if k == "match" then return gen_match(node, ctx) end` line (order doesn't matter, but keep them together):
```lua
  if k == "if" then return gen_if(node, ctx) end
```

Do NOT modify `gen_value`'s `if` branch or `gen_fn_body`'s `if` branch.

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — the if-expression golden + behavioral tests green; the regression golden (let-bound `if` has no `(function()`) green; ALL prior tests still green (existing `if` behavior in binding/branch/return position is unchanged).

- [ ] **Step 5: Commit**

```bash
git add omelette/codegen.lua spec/if_expression_spec.lua
git commit -m "feat: if is a first-class expression (gen_if IIFE in codegen.expr)"
```

---

## Self-Review

**1. Spec coverage:**
- `gen_if` IIFE (falsy-safe via `gen_fn_body`) + `if` dispatch in `expr` → Task 1. ✓
- `if` as binop operand / pipe LHS / comprehension yield / call arg / nested → Task 1 behavioral. ✓
- Common `let x = if …` keeps non-closure lowering (`gen_value`/`gen_fn_body` untouched) → Task 1 regression golden. ✓
- Falsy-safe → Task 1 test. ✓
- No parser/typecheck/etc. changes (parser already parses `(if …)`; typecheck already synths `if`) → correct, not touched. ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". Complete code + full test assertions. The golden `:find` substrings are pinned to the `gen_if` output shape (verified by tracing `(if c then 1 else 2)`).

**3. Type consistency:** `gen_if(node, ctx)` uses the existing `if` node fields (`cond`, `then_branch`, `else_branch`) — same as `gen_value`'s `if` branch — and calls the existing `expr`/`gen_fn_body` with their established signatures. Mirrors `gen_match`'s structure. ✓
