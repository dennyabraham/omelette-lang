# Omelette Runnable Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `docs/guide.md` whose every ` ```egg ` example is compiled/run in the test suite (three modes: smoke / output / error), so the docs can't drift.

**Architecture:** Task 1 builds a `spec/support/doctest.lua` (extract fenced blocks + run each), unit-tests it against inline fixtures (proving it catches drift), and wires `spec/doc_guide_spec.lua` to verify `docs/guide.md` (seeded with a few real examples). Task 2 writes the full guide — every example verified by the Task-1 harness.

**Tech Stack:** Pure Lua; the existing `spec/run.lua` harness (auto-discovers `spec/*_spec.lua`); `omelette.compiler` (`eval`/`check`).

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline**. Test runner is `luajit spec/run.lua`.
- Example blocks are ` ```egg `; expected output/error is a **paired following fence** (` ```output ` / ` ```error `).
- Three modes: **smoke** (egg alone → `compiler.eval` succeeds), **output** (egg + `output` → captured `print` stdout matches), **error** (egg + `error` → `compiler.check` diagnostic contains the text).
- Each egg block is a **self-contained** program. Verification lives in `spec/` (runs with `luajit spec/run.lua`, hence CI).
- `spec/support/*.lua` are modules (the runner only auto-runs `spec/*_spec.lua`).

---

## Data Structures (authoritative reference)

`doctest.extract(md)` returns an ordered list of blocks:
```lua
{ code = <string>, mode = "smoke"|"output"|"error", expect = <string>|nil, line = <int> }
```
`doctest.run_block(block)` returns `ok (boolean), detail (string|nil)`.

---

### Task 1: The doctest harness (`doctest.lua`) + unit tests + seed guide

**Files:**
- Create: `spec/support/doctest.lua`
- Create: `spec/doctest_spec.lua`
- Create: `docs/guide.md` (seed — a handful of real examples across all three modes)
- Create: `spec/doc_guide_spec.lua`

**Interfaces:**
- Consumes: `omelette.compiler` (`eval`, `check`).
- Produces: `doctest.extract(md) -> blocks`, `doctest.run_block(block) -> ok, detail` (Task 2 relies on these to verify the full guide).

- [ ] **Step 1: Write the failing test**

`spec/doctest_spec.lua`:
```lua
local h = require("spec.support.harness")
local dt = require("spec.support.doctest")

h.describe("doctest.extract", function()
  h.it("an egg block alone is smoke", function()
    local b = dt.extract("```egg\nprint(1)\n```")
    h.eq(#b, 1); h.eq(b[1].mode, "smoke"); h.eq(b[1].code, "print(1)")
  end)
  h.it("egg + output pairs into an output block", function()
    local b = dt.extract("```egg\nprint(1)\n```\n```output\n1\n```")
    h.eq(#b, 1); h.eq(b[1].mode, "output"); h.eq(b[1].expect, "1")
  end)
  h.it("egg + error pairs into an error block", function()
    local b = dt.extract("```egg\nx\n```\n```error\nboom\n```")
    h.eq(b[1].mode, "error"); h.eq(b[1].expect, "boom")
  end)
  h.it("egg followed by a non-expectation fence stays smoke", function()
    local b = dt.extract("```egg\nprint(1)\n```\n```lua\nwhatever\n```")
    h.eq(#b, 1); h.eq(b[1].mode, "smoke")
  end)
  h.it("ignores prose and non-egg fences", function()
    h.eq(#dt.extract("hello\n```text\nnope\n```\nworld"), 0)
  end)
  h.it("records the source line of the egg block", function()
    local b = dt.extract("intro\n\n```egg\nprint(1)\n```")
    h.eq(b[1].line, 3)
  end)
end)

h.describe("doctest.run_block", function()
  h.it("passes a correct smoke block", function()
    h.truthy((dt.run_block({ code = "let x = 1\nprint(x)", mode = "smoke" })))
  end)
  h.it("fails a smoke block that does not compile", function()
    h.truthy(not (dt.run_block({ code = "let = ", mode = "smoke" })))
  end)
  h.it("passes a correct output block", function()
    h.truthy((dt.run_block({ code = "print(2 + 3)", mode = "output", expect = "5" })))
  end)
  h.it("fails a wrong-output block", function()
    h.truthy(not (dt.run_block({ code = "print(2 + 3)", mode = "output", expect = "6" })))
  end)
  h.it("passes an error block whose diagnostic contains the text", function()
    h.truthy((dt.run_block({
      code = "type Shape = | Circle { radius } | Origin\n"
        .. "pub let f s = match s with | Circle { radius } -> radius",
      mode = "error", expect = "missing Origin" })))
  end)
  h.it("fails an error block that actually checks clean", function()
    h.truthy(not (dt.run_block({ code = "let x = 1", mode = "error", expect = "anything" })))
  end)
  h.it("fails an error block whose diagnostic lacks the text", function()
    h.truthy(not (dt.run_block({ code = 'let x: number = "hi"', mode = "error", expect = "zzz-not-present" })))
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `module 'spec.support.doctest' not found`.

- [ ] **Step 3: Implement `spec/support/doctest.lua`**

```lua
local compiler = require("omelette.compiler")
local M = {}

local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

-- extract fenced code blocks; pair an `egg` block with an immediately-following
-- `output`/`error` fence, else it is smoke.
function M.extract(md)
  local lines = {}
  for line in (md .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  -- 1) tokenize every fenced block: { info, code, line }
  local fences, i = {}, 1
  while i <= #lines do
    local info = lines[i]:match("^```(%a*)%s*$")
    if info ~= nil then
      local start_line, body = i, {}
      i = i + 1
      while i <= #lines and not lines[i]:match("^```%s*$") do
        body[#body + 1] = lines[i]; i = i + 1
      end
      fences[#fences + 1] = { info = info, code = table.concat(body, "\n"), line = start_line }
      i = i + 1  -- skip the closing ```
    else
      i = i + 1
    end
  end
  -- 2) pair egg blocks with a following output/error fence
  local blocks, j = {}, 1
  while j <= #fences do
    local f = fences[j]
    if f.info == "egg" then
      local nxt = fences[j + 1]
      if nxt and (nxt.info == "output" or nxt.info == "error") then
        blocks[#blocks + 1] = { code = f.code, mode = nxt.info, expect = nxt.code, line = f.line }
        j = j + 2
      else
        blocks[#blocks + 1] = { code = f.code, mode = "smoke", expect = nil, line = f.line }
        j = j + 1
      end
    else
      j = j + 1
    end
  end
  return blocks
end

-- run `code` through compiler.eval while capturing print; returns ok, errmsg, output
local function eval_capturing(code)
  local buf, old = {}, _G.print
  _G.print = function(...)
    local parts, n = {}, select("#", ...)
    for k = 1, n do parts[k] = tostring((select(k, ...))) end
    buf[#buf + 1] = table.concat(parts, "\t")
  end
  local ok, mod, err = pcall(compiler.eval, code)
  _G.print = old
  if not ok then return false, tostring(mod), table.concat(buf, "\n") end   -- Lua runtime error
  if err then return false, tostring(err.message), table.concat(buf, "\n") end -- compile diagnostic
  return true, nil, table.concat(buf, "\n")
end

function M.run_block(block)
  if block.mode == "error" then
    local diags, err = compiler.check(block.code)
    if err then
      if err.message:find(block.expect, 1, true) then return true end
      return false, "line " .. tostring(block.line) .. ": parse error did not contain '"
        .. block.expect .. "': " .. err.message
    end
    if not diags or #diags == 0 then
      return false, "line " .. tostring(block.line) .. ": expected a diagnostic containing '"
        .. block.expect .. "', but it checked clean"
    end
    for _, d in ipairs(diags) do
      if d.message:find(block.expect, 1, true) then return true end
    end
    return false, "line " .. tostring(block.line) .. ": no diagnostic contained '"
      .. block.expect .. "'; got: " .. diags[1].message
  end

  local ok, errmsg, out = eval_capturing(block.code)
  if block.mode == "smoke" then
    if not ok then return false, "line " .. tostring(block.line) .. ": expected clean run, got: " .. tostring(errmsg) end
    return true
  elseif block.mode == "output" then
    if not ok then return false, "line " .. tostring(block.line) .. ": run error: " .. tostring(errmsg) end
    if trim(out) ~= trim(block.expect) then
      return false, "line " .. tostring(block.line) .. ": output mismatch\n  expected: ["
        .. trim(block.expect) .. "]\n  got:      [" .. trim(out) .. "]"
    end
    return true
  end
  return false, "unknown mode " .. tostring(block.mode)
end

return M
```

- [ ] **Step 4: Run to verify the harness tests pass**

Run: `luajit spec/run.lua`
Expected: PASS — all `doctest.extract` / `doctest.run_block` unit tests green (the harness passes correct blocks and catches wrong-output, non-compiling smoke, clean-when-error-expected, and wrong-error-text). All prior tests still green.

- [ ] **Step 5: Seed `docs/guide.md` and wire `spec/doc_guide_spec.lua`**

Create `docs/guide.md` (a small real seed exercising all three modes — Task 2 expands it):
````markdown
# The Omelette Guide

Omelette is a small ML-flavored language that compiles to Lua 5.1.

## Values and functions

```egg
let add x y = x + y
print(add(2, 3))
```
```output
5
```

## Pattern matching

```egg
let describe n =
  match n with
  | 0 -> "zero"
  | _ -> "many"
print(describe(0))
```
```output
zero
```

## Exhaustiveness

The type checker rejects a `match` that misses a constructor:

```egg
type Shape = | Circle { radius } | Origin
let area s = match s with | Circle { radius } -> radius
```
```error
non-exhaustive match on 'Shape': missing Origin
```
````

Create `spec/doc_guide_spec.lua`:
```lua
local h = require("spec.support.harness")
local dt = require("spec.support.doctest")

local fh = io.open("docs/guide.md", "r")
local md = assert(fh, "docs/guide.md must exist"):read("*a")
fh:close()

h.describe("docs/guide.md examples run", function()
  local blocks = dt.extract(md)
  h.it("the guide has runnable examples", function() h.truthy(#blocks > 0) end)
  for _, b in ipairs(blocks) do
    h.it("guide.md line " .. b.line .. " (" .. b.mode .. ")", function()
      local ok, detail = dt.run_block(b)
      if not ok then error(detail, 2) end
    end)
  end
end)
```

- [ ] **Step 6: Run to verify the seed guide passes**

Run: `luajit spec/run.lua`
Expected: PASS — the three seed examples verify (one output, one output, one error); all prior tests still green.

- [ ] **Step 7: Commit**

```bash
git add spec/support/doctest.lua spec/doctest_spec.lua spec/doc_guide_spec.lua docs/guide.md
git commit -m "feat: runnable-docs harness (smoke/output/error) + seed guide"
```

---

### Task 2: The full guide (`docs/guide.md`)

**Files:**
- Modify: `docs/guide.md` (expand the seed into the full guide)

**Interfaces:**
- Consumes: the doctest harness (Task 1) — every ` ```egg ` block is verified by `spec/doc_guide_spec.lua`.

- [ ] **Step 1: Expand `docs/guide.md` to the full guide**

Write a terse, example-driven guide covering, in order, each with at least one **verified** example
(prefer `output` mode with a `print`; use `error` mode for the type-checker sections). Keep prose
minimal; let the examples carry it. Sections:
1. **What is Omelette** — one paragraph; it compiles to Lua 5.1; mention `omelette run/build/check` (prose, no example needed).
2. **Values & bindings** — `let`, `pub let`, immutability. Example: bind values and `print` one (`output`).
3. **Functions & partial application** — `let f x y = …` headers, `f(x)` calls, `_` holes. Example: define `add`, make `inc = add(1, _)`, `print(inc(4))` (`output`).
4. **Pipes** — `|>` threads the LHS as the first argument. Example: `print([1,2,3] |> length)` or a `std.list` pipe (`output`).
5. **Control flow** — `if`/`then`/`else` is an expression. Example: `print(if 3 > 2 then "yes" else "no")` (`output`).
6. **Pattern matching** — `match`, literals, variables, array `[a, b]` and record `{ x, y }` destructuring, `when` guards. Example: destructure a small value and `print` (`output`).
7. **Comprehensions & ranges** — list `[ f(x) | x <- xs ]`, dict `{ k => v | … }`, `[a to b]`. Example: `print(length([ x * x | x <- [1 to 3] ]))` or similar (`output`).
8. **Sum types** — `type` declarations, `Ctor { field = v }` construction, constructor patterns. Example: an `Option`/`Shape` round-trip that `print`s a result (`output`).
9. **Optional typing & exhaustiveness** — `:` annotations; `omelette check`. At least one **`error`** example for a type mismatch (`let x: number = "hi"` → text contains `number`) and one **`error`** example for a non-exhaustive match (text contains `missing`). A clean annotated example may also be shown (`output`/smoke).
10. **Standard library tour** — a few `std.list` / `std.string` / `std.table` highlights via `require`. Example: `let list = require("std.list")` then `print(list.sum([1,2,3]))` (`output`) — verify the actual exported names first.
11. **Lua interop** — calling Lua globals (`print`, `string.*`), `require`, and `lua "…"` raw. Example: a smoke or `output` block.

Requirements for every example:
- Self-contained (defines everything it uses; a block never depends on a previous block).
- `output` examples end by `print`-ing the value being demonstrated; the paired `output` fence holds the exact stdout.
- `error` examples pair with an `error` fence whose text is a **substring** of the real diagnostic — run the compiler to confirm the exact wording before pinning it.
- Verify stdlib function names against `std/*.egg` before writing stdlib examples (don't guess).

- [ ] **Step 2: Run to verify every example passes**

Run: `luajit spec/run.lua`
Expected: PASS — every guide block verified green by `spec/doc_guide_spec.lua`; all prior tests still green. If any block fails, fix the guide (or the expected output/error) until green — the guide must be true.

- [ ] **Step 3: Point the README at the guide**

Update `README.md` to add a one-line pointer to `docs/guide.md` (e.g. "See docs/guide.md for the language guide — every example is verified in CI.").

- [ ] **Step 4: Commit**

```bash
git add docs/guide.md README.md
git commit -m "docs: full runnable language guide (all examples CI-verified)"
```

---

## Self-Review

**1. Spec coverage:**
- Three block modes (smoke/output/error) → Task 1 `doctest.run_block` + tests. ✓
- Paired-fence extraction (egg + output/error) → Task 1 `extract` + tests. ✓
- Harness's own drift-catching unit-tested → Task 1 `doctest_spec.lua` (wrong output / non-compiling smoke / clean-when-error / wrong error text). ✓
- Guide verified as part of `spec/run.lua` (hence CI) → Task 1 `doc_guide_spec.lua`. ✓
- Self-contained blocks; `docs/guide.md` content across all sections → Task 2. ✓
- README pointer → Task 2 Step 3. ✓
- Deferred (website/playground) → not implemented (correct). ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". `doctest.lua`, all unit tests, the seed guide, and `doc_guide_spec.lua` are given in full. Task 2's guide content is specified section-by-section with the required verified-example mode for each — the prose is the deliverable, but each section's example shape and mode are pinned, and the instruction to confirm exact diagnostic/stdlib wording against the compiler is explicit (no guessing).

**3. Type consistency:** `extract` returns `{code, mode, expect, line}`; `run_block` consumes exactly those fields (`block.code`/`block.mode`/`block.expect`/`block.line`). `doc_guide_spec.lua` uses `extract` then `run_block`, matching Task 1's produced API. `compiler.eval(code) -> mod, err` and `compiler.check(code) -> diags, err` match the real compiler signatures. ✓
