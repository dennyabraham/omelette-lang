# Omelette Indexing & Length Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add read indexing `xs[i]` and length `#xs` to Omelette, compiling directly to Lua `t[k]` and `#t`.

**Architecture:** Two small additive changes to the existing pipeline. Length: a new `#` operator (lexer single-char op → parser unary → codegen). Indexing: a postfix `[key]` form (parser `parse_postfix` → codegen `index` node). No changes to compiler/resolver/CLI/REPL/searcher.

**Tech Stack:** Pure Lua compiler, tested with the in-repo harness under `luajit`.

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline** (no `//`, no native bitops, no `goto`, no `<close>`). Test runner is `luajit spec/run.lua`.
- AST nodes are **plain tables tagged with a `kind` string**, carrying `line`/`col`.
- Indexing is **read-only** — there is no `xs[i] = v` assignment form (surface stays immutable).
- `xs[i]` reads a table at one key; `#xs` is Lua's length (table element count / string byte length).
- `s[i]` on a string is Lua-`nil` and is **not** a supported character-access form (do not add string indexing); `#s` (string length) **is** supported.

---

## Data Structures (authoritative reference)

```lua
{ kind = "index", obj = <expr>, key = <expr>, line, col }   -- new (Task 2)
{ kind = "unop", op = "#", operand = <expr>, line, col }    -- reuses existing unop (Task 1)
```

Existing relevant code (unchanged shapes): `unop` nodes already exist for `-`/`not`; `parse_postfix` already handles `.field` and `(call)`.

---

### Task 1: Length operator `#`

**Files:**
- Modify: `omelette/lexer.lua` (add `#` to `SINGLE_OPS`, ~line 13)
- Modify: `omelette/parser.lua:67-75` (`parse_unary`)
- Modify: `omelette/codegen.lua:72-75` (the `unop` case in `expr`)
- Create: `spec/length_spec.lua`

**Interfaces:**
- Consumes: existing `lexer.tokenize`, `parser.parse_expr_string`, `codegen.expr`/`new_ctx`, `compiler.eval`.
- Produces: `#x` lexes as `{op,"#"}`, parses to `{kind="unop", op="#", operand}`, and compiles to `(#x)`.

- [ ] **Step 1: Write the failing test**

`spec/length_spec.lua`:
```lua
local h = require("spec.support.harness")
local lexer = require("omelette.lexer")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end

h.describe("length operator", function()
  h.it("lexes # as an op token", function()
    local toks = assert(lexer.tokenize("#xs"))
    h.eq(toks[1], { type = "op", value = "#", line = 1, col = 1 })
    h.eq(toks[2].value, "xs")
  end)
  h.it("parses #xs as a unop", function()
    local e = assert(parser.parse_expr_string("#xs"))
    h.eq(e.kind, "unop")
    h.eq(e.op, "#")
    h.eq(e.operand.name, "xs")
  end)
  h.it("binds tighter than binary operators", function()
    local e = assert(parser.parse_expr_string("#xs + 1"))
    h.eq(e.kind, "binop"); h.eq(e.op, "+")
    h.eq(e.lhs.kind, "unop"); h.eq(e.lhs.op, "#")
  end)
  h.it("emits (#x)", function()
    h.eq(gen("#xs"), "(#xs)")
  end)
  h.it("behavioral: length of an array and a string", function()
    local mod = assert(compiler.eval('pub let a = #[10, 20, 30]\npub let b = #"hello"'))
    h.eq(mod.a, 3)
    h.eq(mod.b, 5)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `#` is an unexpected character in the lexer (or the unop assertions fail).

- [ ] **Step 3: Implement**

In `omelette/lexer.lua`, add `["#"] = true` to the `SINGLE_OPS` table (around line 13). For example, change:
```lua
local SINGLE_OPS = { ["+"]=true,["-"]=true,["*"]=true,["/"]=true,["%"]=true,
  ["<"]=true,[">"]=true,["="]=true }
```
to:
```lua
local SINGLE_OPS = { ["+"]=true,["-"]=true,["*"]=true,["/"]=true,["%"]=true,
  ["<"]=true,[">"]=true,["="]=true,["#"]=true }
```

In `omelette/parser.lua`, change the `parse_unary` condition (line 69) to also accept `#`:
```lua
function Parser:parse_unary()
  local t = self:peek()
  if self:at("op", "-") or self:at("op", "#") or self:at("keyword", "not") then
    self:next()
    local operand = self:parse_unary()
    return { kind = "unop", op = t.value, operand = operand, line = t.line, col = t.col }
  end
  return self:parse_postfix()
end
```

In `omelette/codegen.lua`, change the `unop` case (lines 72-75) so `#` and `-` emit with no trailing space and `not` keeps its space:
```lua
  if k == "unop" then
    local op = node.op == "not" and "not " or node.op  -- "not " | "-" | "#"
    return "(" .. op .. expr(node.operand, ctx) .. ")"
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — length tests green, all prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add omelette/lexer.lua omelette/parser.lua omelette/codegen.lua spec/length_spec.lua
git commit -m "feat: add length operator #"
```

---

### Task 2: Read indexing `xs[i]`

**Files:**
- Modify: `omelette/parser.lua:78-105` (`parse_postfix` — add a `[` branch)
- Modify: `omelette/codegen.lua` (add an `index` case in `expr`, before the final `error(...)`)
- Create: `spec/index_spec.lua`

**Interfaces:**
- Consumes: Task 1's `#` operator (used in the integration test); existing `parse_postfix`, `expr`.
- Produces: `xs[i]` parses to `{kind="index", obj, key}` and compiles to `obj[key]`.

- [ ] **Step 1: Write the failing test**

`spec/index_spec.lua`:
```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function expr(s) return assert(parser.parse_expr_string(s)) end
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end

h.describe("read indexing", function()
  h.it("parses xs[i] as an index node", function()
    local e = expr("xs[1]")
    h.eq(e.kind, "index")
    h.eq(e.obj.name, "xs")
    h.eq(e.key.value, 1)
  end)
  h.it("nests chained indexing grid[i][j]", function()
    local e = expr("grid[i][j]")
    h.eq(e.kind, "index")
    h.eq(e.key.name, "j")
    h.eq(e.obj.kind, "index")
    h.eq(e.obj.key.name, "i")
  end)
  h.it("still parses a bare array literal in primary position", function()
    h.eq(expr("[1, 2, 3]").kind, "array")
  end)
  h.it("rejects a two-key index", function()
    local _, err = parser.parse_expr_string("xs[1, 2]")
    h.truthy(err ~= nil)
  end)
  h.it("emits obj[key]", function()
    h.eq(gen("xs[1]"), "xs[1]")
    h.eq(gen('record["key"]'), 'record["key"]')
  end)
  h.it("behavioral: index into an array and a record", function()
    local mod = assert(compiler.eval('pub let a = [10, 20, 30][2]\npub let b = { x = 1, y = 2 }["y"]'))
    h.eq(mod.a, 20)
    h.eq(mod.b, 2)
  end)
  h.it("behavioral: indexing + length enable a tail-recursive fold", function()
    local mod = assert(compiler.eval(table.concat({
      "let sum_go xs acc i =",
      "  if i > #xs then acc",
      "  else sum_go(xs, acc + xs[i], i + 1)",
      "pub let sum xs = sum_go(xs, 0, 1)",
    }, "\n")))
    h.eq(mod.sum({ 3, 4, 5 }), 12)
    h.eq(mod.sum({}), 0)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `xs[1]` parses `xs`, then `[1]` is left unconsumed by `parse_postfix`, so `parse_expr_string` errors on trailing input (`expected eof`), or the `index` assertions fail.

- [ ] **Step 3: Implement**

In `omelette/parser.lua`, add a `[` branch inside the `parse_postfix` `while` loop, between the `(call)` branch and the `else break` (after line 99, before line 100):
```lua
    elseif self:at("punct", "[") then
      local t = self:next()
      local key = self:parse_expr()
      self:expect("punct", "]")
      node = { kind = "index", obj = node, key = key, line = t.line, col = t.col }
```

In `omelette/codegen.lua`, add the `index` case in `expr`, immediately before the final `error("codegen: cannot emit expression of kind ...")` line:
```lua
  if k == "index" then return expr(node.obj, ctx) .. "[" .. expr(node.key, ctx) .. "]" end
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — indexing tests green (including the tail-recursive `sum` proving the two primitives compose), all prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add omelette/parser.lua omelette/codegen.lua spec/index_spec.lua
git commit -m "feat: add read indexing xs[i]"
```

---

## Self-Review

**1. Spec coverage:**
- `xs[i]` read indexing (postfix, one key, read-only) → Task 2 (parser + codegen + tests). ✓
- `f[1]` vs `[1]` disambiguation; chained `grid[i][j]`; two-key index error → Task 2 parser tests. ✓
- `#xs` length operator (unary), tables and strings → Task 1 (lexer + parser + codegen + behavioral). ✓
- `#` binds tighter than binary ops → Task 1 precedence test. ✓
- Both compile to Lua 5.1-safe `t[k]` / `#t` → Task 1/2 golden + behavioral. ✓
- Read-only (no `xs[i] = v`) → not implemented anywhere (correct; nothing parses an index on the LHS of `=`). ✓
- No string `s[i]` character access added → not implemented; `#s` behavioral test covers string length only. ✓
- Primitives enable folds → Task 2 tail-recursive `sum` behavioral test. ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". Every code step shows complete code; every test shows full assertions. ✓

**3. Type consistency:** New `index` node uses `obj`/`key` in both Task 2's parser and codegen. `unop` reuses the existing `op`/`operand` fields; the codegen `op` mapping (`"not " | "-" | "#"`) matches the parser emitting `op = t.value`. The behavioral `sum` test in Task 2 relies on Task 1's `#` operator (sequenced after Task 1). ✓
