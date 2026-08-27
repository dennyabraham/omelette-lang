# Negative-Literal Patterns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a negative number literal be used as a pattern — `| -1 -> …` — in `match` and any nested pattern position.

**Architecture:** One addition to `parse_pattern`: a `-` token immediately followed by a `number` token becomes a numeric `lit` pattern with the negated value. Codegen and the type checker are unchanged — the existing `lit` pattern path emits `access == -1`.

**Tech Stack:** Pure Lua (LuaJIT + Lua 5.4 in CI); the `omelette.parser` / `omelette.compiler` modules; the `spec/support/harness.lua` test harness.

## Global Constraints

- Runs on both LuaJIT and Lua 5.4 (CI matrix).
- Only a `-` **directly** followed by a numeric token is a negative literal; a `-` before anything else is untouched and keeps its current behavior (so no existing pattern changes meaning).
- `compiler.compile(source)` returns `lua_string, nil` on success or `nil, err` on failure. `compiler.eval(source)` returns the module table (or `nil, err`).
- Number tokens carry `value` as an actual Lua number (`tonumber(...)`), so negation is `-token.value`.
- Test harness API: `local h = require("spec.support.harness")`; `h.describe`, `h.it`, `h.eq`, `h.truthy`. Run the suite: `luajit spec/run.lua` (prints "N tests, 0 failures").
- The guide's ` ```egg ` examples are compiled/run by the suite (doctest), so a new example is verified by running the suite.

---

### Task 1: Negative-literal patterns in `parse_pattern`

**Files:**
- Modify: `omelette/parser.lua` (`parse_pattern`, near the top after the `wildcard` check ~line 405)
- Create: `spec/negative_pattern_spec.lua`
- Modify: `docs/guide.md` (one verified example, in the pattern-matching section)

**Interfaces:**
- Consumes: `Parser:at(type, value)`, `Parser:peek2()`, `Parser:next()` (existing parser methods); the `lit` pattern node shape `{ kind = "lit", value = <number>, lit_kind = "number" }` (same as the positive-number pattern branch produces).
- Produces: negative numeric `lit` patterns; no new node kinds, no codegen/checker change.

- [ ] **Step 1: Write the failing tests**

Create `spec/negative_pattern_spec.lua`:

```lua
local h = require("spec.support.harness")
local compiler = require("omelette.compiler")

local function val(src, name)
  local mod = assert(compiler.eval(src))
  return mod[name]
end

h.describe("negative-number literal patterns", function()
  h.it("matches a negative integer literal", function()
    h.eq(val('pub let r = match -1 with | -1 -> "a" | _ -> "b"', "r"), "a")
  end)
  h.it("does not match a different value", function()
    h.eq(val('pub let r = match 1 with | -1 -> "a" | _ -> "b"', "r"), "b")
  end)
  h.it("matches a negative float literal", function()
    h.eq(val('pub let r = match -1.5 with | -1.5 -> "a" | _ -> "b"', "r"), "a")
  end)
  h.it("works nested in an array pattern", function()
    h.eq(val("pub let r = match [3, -1] with | [a, -1] -> a | _ -> 0", "r"), 3)
  end)
  h.it("a '-' before a non-number still fails to parse", function()
    local ok = compiler.compile("pub let f = match 0 with | -y -> y | _ -> 0")
    h.truthy(not ok)
  end)
  h.it("the emitted Lua loads", function()
    local lua = assert(compiler.compile('pub let r = match -1 with | -1 -> 1 | _ -> 0'))
    local load_fn = loadstring or load
    h.truthy((load_fn(lua)))
  end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `luajit spec/run.lua 2>&1 | grep -iE "negative|fail" | head`
Expected: FAIL — `-1` in a pattern does not parse yet (the parser hits the identifier path and errors), so the matching cases fail.

- [ ] **Step 3: Add the negative-literal branch to `parse_pattern`**

In `omelette/parser.lua`, in `Parser:parse_pattern()`, immediately after the `wildcard` check (the line `if self:at("punct", "_") then self:next(); return { kind = "wildcard" } end`), insert:

```lua
  -- negative number literal: `-` directly followed by a number token → negated numeric lit.
  -- (Only a numeric follower triggers this; `-x` stays an error, unchanged.)
  if self:at("op", "-") and self:peek2() and self:peek2().type == "number" then
    self:next()                 -- consume '-'
    local num = self:next()     -- the number token (num.value is a Lua number)
    return { kind = "lit", value = -num.value, lit_kind = "number" }
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: the full suite passes (previous count + 6 new cases, 0 failures).

- [ ] **Step 5: Add a guide example and verify the doctest**

In `docs/guide.md`, in the pattern-matching section (after the array-patterns example that ends with `print(sum_first_two([3, 4]))` / `7`), add:

````markdown
Number patterns can be negative:

```egg
let sign n =
  match n with
  | -1 -> "neg one"
  | 0  -> "zero"
  | _  -> "other"
print(sign(-1))
```
```output
neg one
```
````

Then run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: still 0 failures — the doctest harness compiled and ran the new ` ```egg ` example and matched its ` ```output ` (`neg one`).

- [ ] **Step 6: Commit**

```bash
git add omelette/parser.lua spec/negative_pattern_spec.lua docs/guide.md
git commit -m "feat: negative-number literal patterns (| -1 ->)"
```

---

## Post-merge (not a plan task)

Update `docs/ROADMAP.md`: within "Pattern-matching extras", mark negative-literal patterns done and leave or-patterns / as-patterns as the remaining deferred work. (Folded into this feature's PR or the next roadmap touch.)
