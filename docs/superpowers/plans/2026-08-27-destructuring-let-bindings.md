# Destructuring `let` Bindings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow a `let` binding's left-hand side to be a pattern — `let { radius } = circle`, `let [a, b] = pair`, `let (a, b) = tuple`, nested — reusing the match pattern parser, with irrefutable extraction to plain `local`s.

**Architecture:** `parse_let` gains a pattern-LHS branch (when `let` is followed by `{`, `[`, or `(`) with an irrefutable check that rejects `lit`/`ctor_pat`. Codegen adds `pattern_names` (bound names) and `gen_destructure` (direct field/index extraction), wired into block-local (`gen_local_let`), top-level (`gen_top_assign`), and the module forward-declaration + `pub` export in `M.program`. No runtime shape test, no type-system change.

**Tech Stack:** Pure Lua (LuaJIT + Lua 5.4 in CI); `omelette.parser` / `omelette.codegen` / `omelette.compiler`; `spec/support/harness.lua`.

## Global Constraints

- Runs on both LuaJIT and Lua 5.4 (CI matrix).
- Irrefutable only: reject `lit` and `ctor_pat` anywhere in a `let` pattern (they can fail — that is `match`'s job). Record/array/tuple patterns with `var`/`wildcard` leaves are allowed; missing fields/elements bind `nil`.
- Extraction is direct: field access `base.key`, index `base[i]`, no `type`/`#` test. The value is evaluated exactly once (used directly if a bare identifier, else via one `__d` temp).
- Works at block scope (`local`) and top level (assigns forward-declared names); `pub let <pattern> = …` exports every bound name.
- A tuple pattern is an `array_pat` (tuples already desugar to arrays), so `let (a, b) = …` flows through the array path with no extra code.
- `compiler.eval(src)` → module table; `compiler.compile(src)` → `lua, nil` | `nil, err` (err.message a string); `parser.parse(src)` → program AST | `nil, err`. Harness: `require("spec.support.harness")` (`h.describe/it/eq/truthy`). Run: `luajit spec/run.lua`.

---

### Task 1: Parser — pattern LHS on `let` + irrefutable check

**Files:**
- Modify: `omelette/parser.lua` (`Parser:parse_let` — add the pattern branch; add `Parser:check_irrefutable`)
- Test: `spec/destructure_let_parser_spec.lua`

**Interfaces:**
- Consumes: `Parser:parse_pattern()`, `Parser:parse_block_or_expr()`, `Parser:at`, `Parser:expect`, `Parser:fail` (existing).
- Produces: a destructuring `let` node `{ kind = "let", pattern = <pattern>, value = <expr/block>, is_pub, line, col }` (no `name`/`params`) — consumed by Task 2. Non-destructuring lets are unchanged.

- [ ] **Step 1: Write the failing tests**

Create `spec/destructure_let_parser_spec.lua`:

```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local function prog(s) return assert(parser.parse(s)) end

h.describe("destructuring let — parsing", function()
  h.it("parses a record destructuring let", function()
    local node = prog("let { a } = r").stmts[1]
    h.eq(node.kind, "let")
    h.eq(node.pattern.kind, "record_pat")
    h.truthy(node.name == nil)
  end)
  h.it("parses an array destructuring let", function()
    h.eq(prog("let [a, b] = xs").stmts[1].pattern.kind, "array_pat")
  end)
  h.it("parses a tuple destructuring let (paren → array_pat)", function()
    h.eq(prog("let (a, b) = pair").stmts[1].pattern.kind, "array_pat")
  end)
  h.it("a normal value let is unaffected", function()
    local node = prog("let x = 1").stmts[1]
    h.eq(node.name, "x")
    h.truthy(node.pattern == nil)
  end)
  h.it("a normal function let is unaffected", function()
    local node = prog("let f a b = a").stmts[1]
    h.eq(node.name, "f")
    h.truthy(node.params ~= nil)
  end)
  h.it("rejects a refutable pattern (literal slot)", function()
    local ok = parser.parse("let [a, 0] = xs")
    h.truthy(not ok)
  end)
  h.it("rejects a refutable pattern (constructor slot)", function()
    local ok = parser.parse("let { x: Origin } = r")
    h.truthy(not ok)
  end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `luajit spec/run.lua 2>&1 | grep -iE "destructuring let — parsing|fail" | head`
Expected: FAIL — `let {` currently reads `{` where an identifier name is required, so these error.

- [ ] **Step 3: Add the pattern branch and the irrefutable check to the parser**

In `omelette/parser.lua`, in `Parser:parse_let()`, immediately after `self:expect("keyword", "let")` and before `local name = self:expect("ident").value`, insert:

```lua
  -- destructuring binding: `let <pattern> = value` (LHS begins with { [ or ( — a plain
  -- value/function binding always begins with an identifier, so this is unambiguous)
  if self:at("punct", "{") or self:at("punct", "[") or self:at("punct", "(") then
    local pattern = self:parse_pattern()
    self:check_irrefutable(pattern)
    self:expect("op", "=")
    local value = self:parse_block_or_expr()
    return { kind = "let", pattern = pattern, value = value,
             is_pub = is_pub, line = startt.line, col = startt.col }
  end
```

Then add a new method just above `function Parser:parse_let()`:

```lua
-- a let pattern must always match; literal and constructor patterns are refutable.
function Parser:check_irrefutable(pat)
  local k = pat.kind
  if k == "lit" or k == "ctor_pat" then
    self:fail("a let pattern must always match; use 'match' for constructor/literal patterns")
  elseif k == "record_pat" then
    for _, f in ipairs(pat.fields) do self:check_irrefutable(f.pat) end
  elseif k == "array_pat" then
    for _, e in ipairs(pat.elems) do self:check_irrefutable(e) end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: full suite passes, 0 failures (parser cases green; codegen for the new node comes in Task 2, but no test compiles a destructuring let yet).

- [ ] **Step 5: Commit**

```bash
git add omelette/parser.lua spec/destructure_let_parser_spec.lua
git commit -m "feat(parser): pattern LHS on let + irrefutable check"
```

---

### Task 2: Codegen — extraction + integration + tests + guide

**Files:**
- Modify: `omelette/codegen.lua` (add `pattern_names`, `destructure_into`, `gen_destructure`; branch `gen_local_let`, `gen_top_assign`, and `M.program`)
- Test: `spec/destructure_let_spec.lua`
- Modify: `docs/guide.md` (one verified example)

**Interfaces:**
- Consumes: the destructuring `let` node from Task 1 (`node.pattern`, `node.value`, `node.is_pub`); the forward-declared `gen_value` and `M.expr`.
- Produces: emitted Lua binding the pattern's variables.

- [ ] **Step 1: Write the failing tests**

Create `spec/destructure_let_spec.lua`:

```lua
local h = require("spec.support.harness")
local compiler = require("omelette.compiler")
local function eval(src) return assert(compiler.eval(src)) end

h.describe("destructuring let", function()
  h.it("record pun binds the field", function()
    h.eq(eval("pub let { a } = { a = 1, b = 2 }").a, 1)
  end)
  h.it("record rename binds the renamed var", function()
    h.eq(eval("pub let { a: x } = { a = 7 }").x, 7)
  end)
  h.it("nested record", function()
    local m = eval("pub let { p: { x, y } } = { p = { x = 3, y = 4 } }")
    h.eq(m.x, 3); h.eq(m.y, 4)
  end)
  h.it("array positional", function()
    local m = eval("pub let [a, b] = [10, 20, 30]")
    h.eq(m.a, 10); h.eq(m.b, 20)
  end)
  h.it("array shorter than pattern binds nil", function()
    h.eq(eval("pub let [a, b] = [1]").b, nil)
  end)
  h.it("tuple destructuring (paren) works", function()
    local m = eval("pub let (a, b) = (10, 20)")
    h.eq(m.a, 10); h.eq(m.b, 20)
  end)
  h.it("wildcard skips a slot", function()
    local m = eval("pub let [a, _, c] = [1, 2, 3]")
    h.eq(m.a, 1); h.eq(m.c, 3)
  end)
  h.it("pub exports every bound name", function()
    local m = eval("pub let { a, b } = { a = 1, b = 2 }")
    h.eq(m.a, 1); h.eq(m.b, 2)
  end)
  h.it("a destructured name is visible to later top-level bindings (forward-decl)", function()
    h.eq(eval("pub let { base } = { base = 2 }\npub let r = base * 3").r, 6)
  end)
  h.it("works at block scope inside a function", function()
    h.eq(eval("pub let f p =\n  let { x, y } = p\n  x + y\npub let r = f({ x = 3, y = 4 })").r, 7)
  end)
  h.it("evaluates a non-ident value exactly once", function()
    local lua = assert(compiler.compile("pub let { x } = distinctbase(1)"))
    local _, n = lua:gsub("distinctbase", "")
    h.eq(n, 1)
  end)
  h.it("the emitted Lua loads", function()
    local lua = assert(compiler.compile("pub let { a, b } = { a = 1, b = 2 }"))
    local load_fn = loadstring or load
    h.truthy((load_fn(lua)))
  end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `luajit spec/run.lua 2>&1 | grep -iE "destructuring let|distinctbase|fail" | head`
Expected: FAIL — codegen has no handling for a `let` node with `node.pattern`, so these error.

- [ ] **Step 3: Add the codegen helpers**

In `omelette/codegen.lua`, immediately after the `gen_value = function(...) … end` definition (the block that ends `return pad .. target .. " = " .. M.expr(node, ctx)` then `end`) and before `gen_local_let = function`, insert:

```lua
-- collect the variable names a pattern binds (var leaves; wildcards bind nothing).
local function pattern_names(pat, out)
  out = out or {}
  local k = pat.kind
  if k == "var" then out[#out + 1] = pat.name
  elseif k == "record_pat" then for _, f in ipairs(pat.fields) do pattern_names(f.pat, out) end
  elseif k == "array_pat" then for _, e in ipairs(pat.elems) do pattern_names(e, out) end
  end
  return out
end

-- append `[local] <name> = <access>` lines binding a pattern's vars by direct extraction.
local function destructure_into(pat, access, lines, pad, decl)
  local k = pat.kind
  if k == "var" then
    lines[#lines + 1] = pad .. (decl and "local " or "") .. pat.name .. " = " .. access
  elseif k == "record_pat" then
    for _, f in ipairs(pat.fields) do destructure_into(f.pat, access .. "." .. f.key, lines, pad, decl) end
  elseif k == "array_pat" then
    for i, e in ipairs(pat.elems) do destructure_into(e, access .. "[" .. i .. "]", lines, pad, decl) end
  end
  -- wildcard: bind nothing
end

-- destructure `node.value` into `pattern`'s vars. The value is emitted once: directly if a
-- bare identifier, via `gen_value` if if/match/block (statement-lowered), else one `__d` temp.
-- `decl` = true emits `local` (block scope); false assigns forward-declared names (top level).
local function gen_destructure(pattern, value, ctx, pad, decl)
  local lines = {}
  local base
  if value.kind == "ident" then
    base = value.name
  elseif value.kind == "if" or value.kind == "match" or value.kind == "block" then
    lines[#lines + 1] = pad .. "local __d"
    lines[#lines + 1] = gen_value("__d", value, ctx, pad)
    base = "__d"
  else
    lines[#lines + 1] = pad .. "local __d = " .. M.expr(value, ctx)
    base = "__d"
  end
  destructure_into(pattern, base, lines, pad, decl)
  return table.concat(lines, "\n")
end
```

- [ ] **Step 4: Branch the three integration points**

(a) In `gen_local_let = function(node, ctx, pad)`, add at the very top (after `pad = pad or ""`):

```lua
  if node.pattern then
    return gen_destructure(node.pattern, node.value, ctx, pad, true)
  end
```

(b) In `local function gen_top_assign(node, ctx)`, add as the first statement:

```lua
  if node.pattern then
    return gen_destructure(node.pattern, node.value, ctx, "", false)
  end
```

(c) In `function M.program(program)`, change the forward-declared-names collection loop from:

```lua
  for _, node in ipairs(program.stmts) do
    if node.kind == "let" then names[#names + 1] = node.name end
  end
```

to:

```lua
  for _, node in ipairs(program.stmts) do
    if node.kind == "let" then
      if node.pattern then
        for _, nm in ipairs(pattern_names(node.pattern)) do names[#names + 1] = nm end
      else
        names[#names + 1] = node.name
      end
    end
  end
```

and change the `pub` export line from:

```lua
      if node.is_pub then
        lines[#lines + 1] = "M." .. node.name .. " = " .. node.name
      end
```

to:

```lua
      if node.is_pub then
        if node.pattern then
          for _, nm in ipairs(pattern_names(node.pattern)) do
            lines[#lines + 1] = "M." .. nm .. " = " .. nm
          end
        else
          lines[#lines + 1] = "M." .. node.name .. " = " .. node.name
        end
      end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: full suite passes, 0 failures.

- [ ] **Step 6: Add a guide example and verify the doctest**

In `docs/guide.md`, in the pattern-matching / records area, add:

````markdown
A `let` binding can destructure a record, array, or tuple directly:

```egg
let { x, y } = { x = 3, y = 4 }
print(x * y)
```
```output
12
```
````

Then run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: still 0 failures — the doctest harness compiled and ran the new example and matched its `output` (`12`).

- [ ] **Step 7: Commit**

```bash
git add omelette/codegen.lua spec/destructure_let_spec.lua docs/guide.md
git commit -m "feat(codegen): destructuring let (record/array/tuple, block + top-level + pub)"
```

---

## Post-merge (not a plan task)

Update `docs/ROADMAP.md`: move "Destructuring let bindings" to Shipped; note tuple patterns in `let` work now that tuples has landed.
