# Omelette Richer Pattern Matching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `match` with variable-binding, array/record destructuring (pun + rename, nested), and guards; compile match to an IIFE (making it a first-class expression); non-exhaustive match raises a runtime error.

**Architecture:** Task 1 adds the `when` keyword and a `Parser:parse_pattern()` (variable/array/record/literal/wildcard) plus guards, producing new pattern AST nodes — codegen still uses the old literal/wildcard path so existing tests pass. Task 2 rewrites codegen: a `compile_pattern` helper + a `gen_match` IIFE, wired into `codegen.expr` (match becomes an expression), collapsing the old `gen_value`/`gen_fn_body` match special-cases. Task 3 updates the type checker to bind pattern variables (as `any`) and synth guards.

**Tech Stack:** Pure Lua compiler, tested with the in-repo harness under `luajit`.

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline**. Test runner is `luajit spec/run.lua`.
- Match compiles to an **IIFE** (valid in any expression position), Lua 5.1-safe (`type()`, `#`, `for`-free, function expr).
- No-match → `error("match: no matching case")`.
- Record pattern tests table-ness only (fields bind, nil if absent). Array pattern tests `type=="table"` **and exact length**.
- Bound pattern variables are typed `any` (no inference in this cut). No new false positives.

---

## Data Structures (authoritative reference)

Pattern AST nodes (Task 1, consumed by Tasks 2/3):
```lua
{ kind = "wildcard" }
{ kind = "lit", value = <any>, lit_kind = <"number"|"string"|"bool"|"nil"> }   -- existing shape
{ kind = "var", name = <string> }
{ kind = "array_pat", elems = { <pattern>... } }
{ kind = "record_pat", fields = { { key = <string>, pat = <pattern> }... } }
```
`match` case gains an optional `guard`: `{ pattern = <pattern>, guard = <expr>|nil, body = <expr> }`.

---

### Task 1: Parser — `parse_pattern`, `when` guards

**Files:**
- Modify: `omelette/lexer.lua` (add `when` to `KEYWORDS`)
- Modify: `omelette/parser.lua` (add `Parser:parse_pattern`; rewrite `Parser:parse_match`)
- Create: `spec/pattern_parse_spec.lua`

**Interfaces:**
- Produces the pattern AST nodes + `guard` above. Codegen unchanged in this task (still uses the old literal/wildcard path — existing match behavioral tests keep passing because `lit`/`wildcard` shapes are unchanged).

- [ ] **Step 1: Write the failing test**

`spec/pattern_parse_spec.lua`:
```lua
local h = require("spec.support.harness")
local lexer = require("omelette.lexer")
local parser = require("omelette.parser")
local function cases(s) return assert(parser.parse("pub let f v = match v with " .. s)).stmts[1].value.cases end

h.describe("pattern parsing", function()
  h.it("lexes when as a keyword", function()
    local toks = assert(lexer.tokenize("x when y"))
    h.eq(toks[2], { type = "keyword", value = "when", line = 1, col = 3 })
  end)
  h.it("parses literal and wildcard (regression)", function()
    local c = cases("| 0 -> 1 | _ -> 2")
    h.eq(c[1].pattern, { kind = "lit", value = 0, lit_kind = "number" })
    h.eq(c[2].pattern.kind, "wildcard")
    h.eq(c[1].guard, nil)
  end)
  h.it("parses a variable pattern", function()
    local c = cases("| n -> n")
    h.eq(c[1].pattern, { kind = "var", name = "n" })
  end)
  h.it("parses an array pattern with nesting", function()
    local c = cases("| [a, [b, c]] -> a")
    h.eq(c[1].pattern.kind, "array_pat")
    h.eq(c[1].pattern.elems[1], { kind = "var", name = "a" })
    h.eq(c[1].pattern.elems[2].kind, "array_pat")
    h.eq(c[1].pattern.elems[2].elems[2], { kind = "var", name = "c" })
  end)
  h.it("parses a record pattern with pun and rename", function()
    local c = cases("| { x, y: b } -> x")
    h.eq(c[1].pattern.kind, "record_pat")
    h.eq(c[1].pattern.fields[1], { key = "x", pat = { kind = "var", name = "x" } })
    h.eq(c[1].pattern.fields[2].key, "y")
    h.eq(c[1].pattern.fields[2].pat, { kind = "var", name = "b" })
  end)
  h.it("parses a guard", function()
    local c = cases("| x when x > 0 -> 1 | _ -> 2")
    h.eq(c[1].pattern.kind, "var")
    h.eq(c[1].guard.kind, "binop")
    h.eq(c[1].guard.op, ">")
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `when` isn't a keyword; `| n ->` parses as a literal (old logic), so the `var`/`array_pat`/`record_pat`/`guard` assertions fail.

- [ ] **Step 3: Implement**

In `omelette/lexer.lua`, add `["when"]=true` to the `KEYWORDS` table (alongside `let`/`pub`/…/`to`).

In `omelette/parser.lua`, add a `Parser:parse_pattern` method (place it just before `Parser:parse_match`):
```lua
function Parser:parse_pattern()
  if self:at("punct", "_") then self:next(); return { kind = "wildcard" } end
  if self:at("punct", "[") then
    self:next()
    local elems = {}
    if not self:at("punct", "]") then
      repeat elems[#elems + 1] = self:parse_pattern() until not self:accept_comma()
    end
    self:expect("punct", "]")
    return { kind = "array_pat", elems = elems }
  end
  if self:at("punct", "{") then
    self:next()
    local fields = {}
    if not self:at("punct", "}") then
      repeat
        local key = self:expect("ident").value
        local pat
        if self:at("op", ":") then self:next(); pat = self:parse_pattern()
        else pat = { kind = "var", name = key } end
        fields[#fields + 1] = { key = key, pat = pat }
      until not self:accept_comma()
    end
    self:expect("punct", "}")
    return { kind = "record_pat", fields = fields }
  end
  if self:at("number") or self:at("string") or self:at("keyword", "true")
      or self:at("keyword", "false") or self:at("keyword", "nil") then
    local lit = self:parse_primary()
    return { kind = "lit", value = lit.value, lit_kind = lit.kind }
  end
  local id = self:expect("ident")
  return { kind = "var", name = id.value }
end
```

Rewrite `Parser:parse_match`:
```lua
function Parser:parse_match()
  local t = self:expect("keyword", "match")
  local subject = self:parse_expr()
  self:expect("keyword", "with")
  local cases = {}
  while self:at("punct", "|") do
    self:next()
    local pattern = self:parse_pattern()
    local guard = nil
    if self:at("keyword", "when") then self:next(); guard = self:parse_expr() end
    self:expect("op", "->")
    local body = self:parse_expr_or_form()
    cases[#cases + 1] = { pattern = pattern, guard = guard, body = body }
  end
  if #cases == 0 then self:fail("match needs at least one | case") end
  return { kind = "match", subject = subject, cases = cases, line = t.line, col = t.col }
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — pattern-parse tests green; all prior tests still green (existing literal/wildcard match behavioral tests still compile via the unchanged codegen path).

- [ ] **Step 5: Commit**

```bash
git add omelette/lexer.lua omelette/parser.lua spec/pattern_parse_spec.lua
git commit -m "feat: parse rich patterns (var/array/record/guards, when keyword)"
```

---

### Task 2: Codegen — `compile_pattern`, `gen_match` IIFE, match-as-expression

**Files:**
- Modify: `omelette/codegen.lua` (add `compile_pattern` + `gen_match`; add `match` to `expr`; remove the `match` special-cases in `gen_value` and `gen_fn_body`)
- Modify: `spec/codegen_module_spec.lua` (update the old flat-`if/elseif` match golden test to the new IIFE shape)
- Create: `spec/pattern_codegen_spec.lua`

**Interfaces:**
- Consumes: pattern AST (Task 1), existing `expr`, `gen_fn_body`, `ctx.acc`.
- Produces: `codegen.expr` emits an IIFE for `match`. Non-exhaustive match → `error("match: no matching case")`.

- [ ] **Step 1: Write the failing behavioral + golden test**

`spec/pattern_codegen_spec.lua`:
```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end

h.describe("pattern codegen", function()
  h.it("emits an IIFE with a subject temp and a no-match error", function()
    local out = gen("match v with | 0 -> 1 | _ -> 2")
    h.truthy(out:find("^%(function%(%)"))
    h.truthy(out:find("local __m1 = v"))
    h.truthy(out:find("if __m1 == 0 then"))
    h.truthy(out:find('error%("match: no matching case"%)'))
    h.truthy(out:find("end%)%(%)$"))
  end)

  h.it("behavioral: variable binding", function()
    local mod = assert(compiler.eval("pub let f v = match v with | n -> n * 2"))
    h.eq(mod.f(5), 10)
  end)
  h.it("behavioral: literal + wildcard (regression)", function()
    local mod = assert(compiler.eval('pub let f n = match n with | 0 -> "z" | 1 -> "o" | _ -> "m"'))
    h.eq(mod.f(0), "z"); h.eq(mod.f(1), "o"); h.eq(mod.f(7), "m")
  end)
  h.it("behavioral: array destructuring with length discrimination", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let f v = match v with",
      "  | [a] -> a",
      "  | [a, b] -> a + b",
      '  | _ -> 0',
    }, "\n")))
    h.eq(mod.f({ 7 }), 7)
    h.eq(mod.f({ 3, 4 }), 7)
    h.eq(mod.f({ 1, 2, 3 }), 0)
  end)
  h.it("behavioral: record pun and rename", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let f v = match v with | { x, y: b } -> x + b",
    }, "\n")))
    h.eq(mod.f({ x = 1, y = 2 }), 3)
  end)
  h.it("behavioral: nested pattern", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let f v = match v with | [a, [b, c]] -> a + b + c | _ -> 0",
    }, "\n")))
    h.eq(mod.f({ 1, { 2, 3 } }), 6)
    h.eq(mod.f({ 1, 2 }), 0)
  end)
  h.it("behavioral: guard matches or falls through", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let f n = match n with",
      '  | x when x > 10 -> "big"',
      '  | x when x > 0 -> "small"',
      '  | _ -> "other"',
    }, "\n")))
    h.eq(mod.f(20), "big"); h.eq(mod.f(3), "small"); h.eq(mod.f(-1), "other")
  end)
  h.it("behavioral: no-match raises", function()
    local mod = assert(compiler.eval('pub let f n = match n with | 0 -> "z"'))
    h.truthy(h.throws(function() mod.f(9) end))
  end)
  h.it("behavioral: match used as a call argument (first-class expression)", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let label n = tostring(match n with | 0 -> 0 | _ -> 1)",
    }, "\n")))
    h.eq(mod.label(0), "0"); h.eq(mod.label(5), "1")
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `codegen.expr` errors on `match` ("cannot emit expression of kind 'match'"); the IIFE golden and destructuring/guard behavioral tests fail.

- [ ] **Step 3: Implement the codegen**

In `omelette/codegen.lua`, add `compile_pattern` and `gen_match` immediately before `expr = function(node, ctx)` (near `gen_comprehension`/`gen_range`):
```lua
-- walk a pattern against an access expression, appending Lua boolean test strings
-- to `tests` and `"local <name> = <access>"` binding strings to `binds`.
local function compile_pattern(pat, access, ctx, tests, binds)
  local k = pat.kind
  if k == "wildcard" then
    -- always matches, binds nothing
  elseif k == "var" then
    binds[#binds + 1] = "local " .. pat.name .. " = " .. access
  elseif k == "lit" then
    tests[#tests + 1] = access .. " == " .. expr({ kind = pat.lit_kind, value = pat.value }, ctx)
  elseif k == "array_pat" then
    tests[#tests + 1] = "type(" .. access .. ') == "table"'
    tests[#tests + 1] = "#" .. access .. " == " .. #pat.elems
    for i, sub in ipairs(pat.elems) do
      compile_pattern(sub, access .. "[" .. i .. "]", ctx, tests, binds)
    end
  elseif k == "record_pat" then
    tests[#tests + 1] = "type(" .. access .. ') == "table"'
    for _, f in ipairs(pat.fields) do
      compile_pattern(f.pat, access .. "." .. f.key, ctx, tests, binds)
    end
  end
end

-- a match compiles to a self-contained IIFE: the subject is bound once; each case
-- opens `if <tests> then <binds> [if <guard> then] return <body> end`; on no match,
-- errors. Tests are `and`-joined and short-circuit, so structural tests (type/#)
-- always precede the deeper accesses they guard.
local function gen_match(node, ctx)
  ctx.acc = (ctx.acc or 0) + 1
  local subj = "__m" .. ctx.acc
  local lines = { "(function()", "  local " .. subj .. " = " .. expr(node.subject, ctx) }
  for _, c in ipairs(node.cases) do
    local tests, binds = {}, {}
    compile_pattern(c.pattern, subj, ctx, tests, binds)
    local cond = #tests > 0 and table.concat(tests, " and ") or "true"
    lines[#lines + 1] = "  if " .. cond .. " then"
    for _, b in ipairs(binds) do lines[#lines + 1] = "    " .. b end
    if c.guard then
      lines[#lines + 1] = "    if " .. expr(c.guard, ctx) .. " then"
      lines[#lines + 1] = gen_fn_body(c.body, ctx, "      ")
      lines[#lines + 1] = "    end"
    else
      lines[#lines + 1] = gen_fn_body(c.body, ctx, "    ")
    end
    lines[#lines + 1] = "  end"
  end
  lines[#lines + 1] = '  error("match: no matching case")'
  lines[#lines + 1] = "end)()"
  return table.concat(lines, "\n")
end
```

Add the dispatch in `expr`, immediately before the final `error(...)` line:
```lua
  if k == "match" then return gen_match(node, ctx) end
```

Now remove the old match special-cases so match routes through `expr`:
- In `gen_value`, delete the entire `if k == "match" then … end` block (the flat lit/wildcard `if/elseif` lowering). Match then falls through to the generic `return pad .. target .. " = " .. M.expr(node, ctx)`.
- In `gen_fn_body`, change `if k == "if" or k == "match" then` to `if k == "if" then` — match now falls through to `return pad .. "return " .. M.expr(node, ctx)`.

- [ ] **Step 4: Update the module golden test, then run**

Run: `luajit spec/run.lua`
Expected: the new pattern-codegen tests PASS, but `spec/codegen_module_spec.lua`'s existing "lowers a match to an if/elseif chain" golden test FAILS (it asserts the old flat shape like `if n == 0 then`, now `if __m1 == 0 then` inside an IIFE).

Update that test in `spec/codegen_module_spec.lua` to the new IIFE shape — run `gen("...")` on its input to see the real output, then pin `:find` substrings, e.g.:
```lua
  h.it("lowers a match to an IIFE with a no-match error", function()
    local out = gen('pub let f n = match n with | 0 -> "z" | _ -> "m"')
    h.truthy(out:find("local __m1 = n"))
    h.truthy(out:find("if __m1 == 0 then"))
    h.truthy(out:find('error%("match: no matching case"%)'))
  end)
```
(If any other golden test asserts the old flat match shape, update it the same way.)

Run: `luajit spec/run.lua`
Expected: PASS — all pattern tests green; the updated golden test green; ALL prior behavioral tests (incl. the existing falsy-match and stdlib) still green.

- [ ] **Step 5: Commit**

```bash
git add omelette/codegen.lua spec/pattern_codegen_spec.lua spec/codegen_module_spec.lua
git commit -m "feat: compile match to an IIFE with destructuring, guards, no-match error"
```

---

### Task 3: Typecheck — bind pattern variables + synth guards

**Files:**
- Modify: `omelette/typecheck.lua` (the `match` synth walk)
- Create: `spec/pattern_typecheck_spec.lua`

**Interfaces:**
- Consumes: pattern AST (Task 1). Produces: no new diagnostics for pattern bindings/guards (bound vars are `any`); existing checks unaffected.

- [ ] **Step 1: Write the failing test**

`spec/pattern_typecheck_spec.lua`:
```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local tc = require("omelette.typecheck")
local function diags(s) return tc.check(assert(parser.parse(s))) end

h.describe("pattern typecheck", function()
  h.it("no false positives for bindings + destructuring + guards", function()
    h.eq(#diags(table.concat({
      "pub let f v = match v with",
      "  | [a, b] -> a + b",
      "  | { x, y: c } -> x + c",
      '  | n when n > 0 -> n',
      "  | _ -> 0",
    }, "\n")), 0)
  end)
  h.it("a real mismatch elsewhere is still caught", function()
    local d = diags(table.concat({
      "let g v = match v with | n -> n",   -- fine
      'let bad: number = "hi"',             -- real error
    }, "\n"))
    h.truthy(#d >= 1)
    h.truthy(d[1].message:find("number", 1, true))
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — the current `match` synth doesn't bind pattern variables, so `a`/`b`/`x`/`c`/`n` are unknown; synth of `a + b` etc. treats them as `any` (lookup miss → any) so arithmetic wouldn't error… but a guard/body referencing a bound var could mis-synthesize, and (depending on current behavior) the walk may not descend into guards. Confirm the RED (if the first test already passes because unknowns default to `any`, keep the test — it locks the no-false-positive guarantee — and this task's real change is descending into guards/bindings correctly; the second test must pass regardless).

- [ ] **Step 3: Implement**

In `omelette/typecheck.lua`, add a small helper that collects a pattern's bound variable names, then use it in the `match` synth. Add near the top helpers:
```lua
local function collect_pattern_vars(pat, out)
  local k = pat.kind
  if k == "var" then out[#out + 1] = pat.name
  elseif k == "array_pat" then for _, p in ipairs(pat.elems) do collect_pattern_vars(p, out) end
  elseif k == "record_pat" then for _, f in ipairs(pat.fields) do collect_pattern_vars(f.pat, out) end
  end
end
```

Replace the `match` branch of `Checker:synth` so each case is checked in a scope that binds its pattern variables (as `any`) and synths the guard:
```lua
  if k == "match" then
    self:synth(node.subject, env)
    local ty
    for _, c in ipairs(node.cases) do
      local s = scope(env)
      local names = {}
      collect_pattern_vars(c.pattern, names)
      for _, n in ipairs(names) do s.vars[n] = ANY end
      if c.guard then self:synth(c.guard, s) end
      local bt = self:synth(c.body, s)
      if ty == nil then ty = bt elseif ty.kind ~= bt.kind then ty = ANY end
    end
    return ty or ANY
  end
```
(Uses the existing `scope`, `ANY`, and `self:synth`. Guards and bodies are now checked with pattern variables in scope, so a body referencing `a`/`x`/`n` resolves to `any` rather than an unbound miss.)

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — pattern typecheck tests green (no false positives; real mismatch caught); all prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add omelette/typecheck.lua spec/pattern_typecheck_spec.lua
git commit -m "feat: typecheck binds pattern variables (any) and synths guards"
```

---

## Self-Review

**1. Spec coverage:**
- `parse_pattern` (var/array/record pun+rename/nested/literal/wildcard) + `when` guards → Task 1. ✓
- IIFE codegen with `compile_pattern` (type/length tests, bindings), guards, no-match `error`, match-as-expression → Task 2. ✓
- Fixes the ident-pattern rough edge (var pattern) and the wildcard-only-match bug (old flat lowering removed) → Task 2. ✓
- Typecheck binds pattern vars as `any` + synths guards; no false positives → Task 3. ✓
- Runtime error on no-match; record tests table-ness only; array tests type+exact length → Task 2 codegen + tests. ✓
- Deferred (ADT patterns, exhaustiveness, or/as-patterns) → not implemented (correct). ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". Complete code + full test assertions in every step. The golden-test update step says "run `gen(...)` to see real output, then pin" (`:find` substrings, not brittle full-string). ✓

**3. Type consistency:** Pattern node shapes (`var`/`array_pat`/`record_pat`/`lit`/`wildcard`) and the case `guard` field produced in Task 1 are exactly what Task 2's `compile_pattern`/`gen_match` and Task 3's `collect_pattern_vars`/match-synth consume. `gen_match` reuses `ctx.acc` (like comprehensions) and `gen_fn_body` (existing) for bodies. Removing match from `gen_value`/`gen_fn_body` is safe because `expr` now handles it (match is a first-class expression). ✓
