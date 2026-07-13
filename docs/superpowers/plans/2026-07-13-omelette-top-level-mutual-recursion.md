# Omelette Top-Level Mutual Recursion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let top-level functions reference each other in any order (mutual recursion / forward references) by forward-declaring all top-level locals in `M.program`, then assigning each.

**Architecture:** Change only `M.program` in `omelette/codegen.lua`: emit one `local a, b, …` forward-declaration line for all top-level `let` names, then emit each binding as an assignment (function → `function name(...)`, value → `name = expr`, if/match/block → lower into `name`) plus `M.name = name` for `pub`. A new top-level helper `gen_top_assign` does the assignment form; `gen_local_let` (block-internal `let`s) is unchanged.

**Tech Stack:** Pure Lua compiler, tested with the in-repo harness under `luajit`.

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline**. Test runner is `luajit spec/run.lua`.
- The change is isolated to `M.program`; `gen_local_let` (used by block-internal `let`s) must NOT change.
- Behavior is preserved for already-correct modules; `M.f` stays callable.
- Value-binding forward references (a value eagerly reading a not-yet-computed sibling) remain a runtime error — inherent, out of scope.
- Lua caps a function scope at 200 locals; a single module can't exceed ~200 top-level bindings (documented limitation, far beyond realistic modules).

---

### Task 1: Forward-declare top-level locals in `M.program`

**Files:**
- Modify: `omelette/codegen.lua` (add `gen_top_assign`; rewrite `M.program`, currently lines 250-274)
- Modify: `spec/codegen_module_spec.lua` (update golden strings to the new shape)
- Create: `spec/mutual_recursion_spec.lua` (behavioral tests — the TDD driver)

**Interfaces:**
- Consumes: existing `gen_fn_body`, `gen_value`, `M.expr`.
- Produces: `M.program` emits `local M = {}` → `local <names>` → per-binding assignments (+`M.name = name` for pub) → `return M`.

- [ ] **Step 1: Write the failing behavioral tests**

`spec/mutual_recursion_spec.lua`:
```lua
local h = require("spec.support.harness")
local compiler = require("omelette.compiler")

h.describe("top-level mutual recursion", function()
  h.it("mutually recursive functions work (is_even defined first)", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let is_even n = if n == 0 then true else is_odd(n - 1)",
      "pub let is_odd n = if n == 0 then false else is_even(n - 1)",
    }, "\n")))
    h.eq(mod.is_even(4), true)
    h.eq(mod.is_even(3), false)
    h.eq(mod.is_odd(3), true)
  end)
  h.it("mutually recursive functions work (is_odd defined first)", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let is_odd n = if n == 0 then false else is_even(n - 1)",
      "pub let is_even n = if n == 0 then true else is_odd(n - 1)",
    }, "\n")))
    h.eq(mod.is_even(4), true)
    h.eq(mod.is_odd(3), true)
  end)
  h.it("a function may call a sibling defined below it (forward reference)", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let outer x = inner(x) + 1",
      "let inner x = x * 2",
    }, "\n")))
    h.eq(mod.outer(5), 11)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — under the current codegen, `is_odd`/`is_even`/`inner` are referenced before their `local function` is in scope, so calling them hits a nil global (`attempt to call ... a nil value`).

- [ ] **Step 3: Implement the codegen change**

In `omelette/codegen.lua`, add `gen_top_assign` immediately before `function M.program(program)` (line 250):
```lua
-- like gen_local_let but assigns to an already-declared (forward-declared) local.
-- Used only at module top level, where all binding names are declared up front,
-- so top-level functions can reference each other in any order.
local function gen_top_assign(node, ctx)
  if node.params then
    local body = gen_fn_body(node.value, ctx, "  ")
    return "function " .. node.name .. "(" .. table.concat(node.params, ", ") .. ")\n"
      .. body .. "\nend"
  end
  if node.value.kind == "if" or node.value.kind == "match" or node.value.kind == "block" then
    return gen_value(node.name, node.value, ctx, "")
  end
  return node.name .. " = " .. M.expr(node.value, ctx)
end
```

Then replace `M.program` (lines 250-274) with:
```lua
function M.program(program)
  local ctx = M.new_ctx()
  local lines = { "local M = {}" }
  -- forward-declare all top-level let names so top-level functions can reference
  -- each other (and recurse) regardless of definition order
  local names = {}
  for _, node in ipairs(program.stmts) do
    if node.kind == "let" then names[#names + 1] = node.name end
  end
  if #names > 0 then
    lines[#lines + 1] = "local " .. table.concat(names, ", ")
  end
  for _, node in ipairs(program.stmts) do
    if node.kind ~= "let" then
      -- bare top-level expression (side effect)
      lines[#lines + 1] = M.expr(node, ctx)
    else
      lines[#lines + 1] = gen_top_assign(node, ctx)
      if node.is_pub then
        lines[#lines + 1] = "M." .. node.name .. " = " .. node.name
      end
    end
  end
  lines[#lines + 1] = "return M"
  return table.concat(lines, "\n")
end
```

- [ ] **Step 4: Run to verify the behavioral tests pass, then update the golden tests**

Run: `luajit spec/run.lua`
Expected: the mutual-recursion tests now PASS, but some `spec/codegen_module_spec.lua` golden assertions FAIL because the emitted shape changed (from `local function add(...)` to a `local add` forward-declaration + `function add(...)`).

Update the affected assertions in `spec/codegen_module_spec.lua` to the new shape. The pub-function and pub-value tests should become (run `gen(...)` to confirm the exact output, then pin these `:find` substring checks):
```lua
  h.it("forward-declares and emits pub functions as locals aliased onto M", function()
    local out = gen("pub let add x y = x + y")
    h.truthy(out:find("local add"))                 -- forward declaration
    h.truthy(out:find("function add%(x, y%)"))       -- assignment form (no `local function`)
    h.truthy(out:find("M%.add = add"))               -- alias
    h.truthy(not out:find("local function add"))     -- old form gone
  end)
  h.it("forward-declares pub value bindings and aliases onto M", function()
    local out = gen("pub let x = 1")
    h.truthy(out:find("local x"))
    h.truthy(out:find("x = 1"))
    h.truthy(out:find("M%.x = x"))
  end)
  h.it("forward-declares non-pub functions (no M alias)", function()
    local out = gen("let inc x = x + 1")
    h.truthy(out:find("local inc"))
    h.truthy(out:find("function inc%(x%)"))
    h.truthy(not out:find("M%.inc"))
  end)
```
Keep the other module tests (`local M = {}`, `return M`, and the if/match/block lowering tests) — but if any of them assert the old `local function name(` or `M.name = expr` (non-alias) shapes for a top-level pub binding, update them to the new forward-decl + `function name(` + `M.name = name` shape. Run `gen(...)` on the exact input to see the real output and pin it.

- [ ] **Step 5: Run the full suite**

Run: `luajit spec/run.lua`
Expected: PASS — mutual-recursion + forward-reference behavioral tests green, updated golden tests green, and ALL prior behavioral tests (including the stdlib and the `fact` recursion test) still green.

- [ ] **Step 6: Commit**

```bash
git add omelette/codegen.lua spec/codegen_module_spec.lua spec/mutual_recursion_spec.lua
git commit -m "feat: forward-declare top-level locals for mutual recursion"
```

---

## Self-Review

**1. Spec coverage:**
- Forward-declare all top-level names, then assign → Task 1 `M.program` rewrite. ✓
- Assignment forms per kind (function / value / if-match-block) + `M.name = name` for pub → `gen_top_assign` + the pub alias line. ✓
- `gen_local_let` unchanged (block-internal `let`s) → Task 1 touches only `M.program`/adds `gen_top_assign`. ✓
- Behavior preserved; `M.f` callable → full behavioral suite must stay green (Step 5). ✓
- Mutual recursion (both orders) + forward reference → Task 1 behavioral tests. ✓
- Golden tests updated to new shape → Task 1 Step 4. ✓
- Value-binding forward-ref stays a runtime error (inherent) → not implemented, correctly out of scope. ✓
- 200-local limit → documented in the spec; no code needed. ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". `gen_top_assign` and `M.program` shown in full; behavioral tests complete; the golden-test step says "run `gen(...)` to confirm exact output, then pin" for the substring assertions (these are `:find` checks, not brittle full-string golden). ✓

**3. Type consistency:** `gen_top_assign(node, ctx)` uses the same node fields (`params`, `name`, `value`, `value.kind`) as the existing `gen_local_let`, and calls the existing `gen_fn_body`/`gen_value`/`M.expr` with their established signatures. `M.program`'s pub alias line matches the stdlib cycle's `M.name = name` form. ✓
