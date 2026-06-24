# Omelette Standard Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship List, String, and Table standard-library modules written in Omelette, plus the codegen change that lets functions reference each other and recurse by name.

**Architecture:** Task 1 changes codegen so every top-level binding is emitted as a `local` (with `M.name = name` added for `pub`). Tasks 2–4 add `std/list.egg`, `std/string.egg`, `std/table.egg` — each a self-contained Omelette module loaded via `require`. Tasks 2–4 are mutually independent (disjoint files) and may be parallelized after Task 1.

**Tech Stack:** Pure Lua compiler; modules in Omelette; tested with the in-repo harness under `luajit`.

## Parallelization

- **Task 1 is a prerequisite for all of Tasks 2–4** (the modules rely on the local+alias codegen). It must land first.
- **Tasks 2, 3, 4 are independent** — disjoint files (`std/<mod>.egg` + `spec/<mod>_spec.lua`; the test runner auto-discovers specs). They can run concurrently in isolated worktrees and merge without conflict.

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline**. Test runner is `luajit spec/run.lua`.
- Modules are written in Omelette; only `table.sort`, `string.*`, `table.concat` are used as Lua interop.
- Operations are **collection-first** (first arg is the collection) and **immutable** (return new tables; never mutate input). `nil` signals absence (`find`/`first`/`last`/`min`/`max`).
- `require("std.list")` resolves `std/list.egg` via the searcher with the default `./?.egg` root, from the repo-root cwd.
- Within a module, define each function **after** the functions it depends on (Lua `local function` is not in scope before its definition).

---

### Task 1: Codegen — top-level bindings as locals + `M` alias

**Files:**
- Modify: `omelette/codegen.lua:250-275` (`M.program`)
- Modify: `spec/codegen_module_spec.lua` (update golden strings)
- Modify: `spec/compiler_spec.lua` (add a recursion behavioral test)

**Interfaces:**
- Consumes: existing `gen_local_let` (already emits `local function f(...)`, `local x = e`, and `local x` + lowering for if/match/block values).
- Produces: `pub let f x = …` → `local function f(x) … end` then `M.f = f`; `pub let x = e` → `local x = e` then `M.x = x`. Non-pub bindings unchanged. This makes every top-level binding a module-level local (siblings reference it as an upvalue) and closes the deferred "pub recursion-by-name" item.

- [ ] **Step 1: Update the failing golden tests + add a recursion test**

Update `spec/codegen_module_spec.lua` so the `pub` expectations match the new shape. Replace the existing pub-related assertions with these (run the code to confirm exact output, then pin it):
```lua
  h.it("emits pub functions as locals aliased onto M", function()
    local out = gen("pub let add x y = x + y")
    h.truthy(out:find("local function add%(x, y%)"))
    h.truthy(out:find("M%.add = add"))
    h.truthy(not out:find("function M%.add%("))   -- no direct M.add function form
  end)
  h.it("emits pub value bindings as a local aliased onto M", function()
    local out = gen("pub let x = 1")
    h.truthy(out:find("local x = 1"))
    h.truthy(out:find("M%.x = x"))
  end)
  h.it("still emits local functions for non-pub defs", function()
    h.truthy(gen("let inc x = x + 1"):find("local function inc%(x%)"))
  end)
```
(Keep the other module tests — `local M = {}`, `return M`, if/match lowering, block — but if any asserted `function M.name(` directly, update it to the `local function name(...) … M.name = name` shape.)

Add to `spec/compiler_spec.lua` inside the existing describe block:
```lua
  h.it("behavioral: a pub function can recurse by name", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let fact n = if n <= 1 then 1 else n * fact(n - 1)",
    }, "\n")))
    h.eq(mod.fact(5), 120)
  end)
  h.it("behavioral: a pub function can call another pub function", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let double x = x * 2",
      "pub let quad x = double(double(x))",
    }, "\n")))
    h.eq(mod.quad(3), 12)
  end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — the recursion test (`fact` calls itself by name; today `pub let fact` is `function M.fact` and the body's `fact` is a nil global) and the new golden assertions fail.

- [ ] **Step 3: Implement the codegen change**

In `omelette/codegen.lua`, replace the body of `M.program` (lines 250-275) with:
```lua
function M.program(program)
  local ctx = M.new_ctx()
  local lines = { "local M = {}" }
  for _, node in ipairs(program.stmts) do
    if node.kind ~= "let" then
      -- bare top-level expression (side effect)
      lines[#lines + 1] = M.expr(node, ctx)
    else
      -- every binding is a module-level local (so siblings reference it as an
      -- upvalue and functions recurse by name); pub bindings are also aliased onto M
      lines[#lines + 1] = gen_local_let(node, ctx, "")
      if node.is_pub then
        lines[#lines + 1] = "M." .. node.name .. " = " .. node.name
      end
    end
  end
  lines[#lines + 1] = "return M"
  return table.concat(lines, "\n")
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — recursion + golden tests green; all prior behavioral tests still green (`M.f` remains callable).

- [ ] **Step 5: Commit**

```bash
git add omelette/codegen.lua spec/codegen_module_spec.lua spec/compiler_spec.lua
git commit -m "feat: emit top-level bindings as locals + M alias (pub recursion/cross-ref)"
```

---

### Task 2: List module (`std/list.egg`)

**Depends on:** Task 1. **Independent of Tasks 3, 4.**

**Files:**
- Create: `std/list.egg`
- Create: `spec/list_spec.lua`

**Interfaces:**
- Produces a Lua module `std.list` with the functions below (collection-first, immutable).

- [ ] **Step 1: Write the failing behavioral test**

`spec/list_spec.lua`:
```lua
local h = require("spec.support.harness")
require("omelette.searcher").install()
local L = require("std.list")
local function dbl(x) return x * 2 end
local function even(x) return x % 2 == 0 end

h.describe("std.list", function()
  h.it("basics", function()
    h.eq(L.length({1,2,3}), 3)
    h.truthy(L.is_empty({}))
    h.eq(L.first({9,8}), 9)
    h.eq(L.last({9,8}), 8)
    h.eq(L.get({5,6,7}, 2), 6)
    h.eq(L.first({}), nil)
  end)
  h.it("map/filter", function()
    h.eq(L.map({1,2,3}, dbl), {2,4,6})
    h.eq(L.filter({1,2,3,4}, even), {2,4})
  end)
  h.it("reduce/sum/product", function()
    h.eq(L.reduce({1,2,3}, function(a,b) return a+b end, 0), 6)
    h.eq(L.sum({1,2,3,4}), 10)
    h.eq(L.product({1,2,3,4}), 24)
    h.eq(L.sum({}), 0)
  end)
  h.it("all/any/count/contains/index_of/find", function()
    h.truthy(L.all({2,4}, even))
    h.truthy(not L.all({2,3}, even))
    h.truthy(L.any({1,2}, even))
    h.eq(L.count({1,2,3,4}, even), 2)
    h.truthy(L.contains({1,2,3}, 2))
    h.truthy(not L.contains({1,2,3}, 9))
    h.eq(L.index_of({7,8,9}, 8), 2)
    h.eq(L.index_of({7,8,9}, 5), nil)
    h.eq(L.find({1,3,4,5}, even), 4)
    h.eq(L.find({1,3,5}, even), nil)
  end)
  h.it("min/max", function()
    h.eq(L.min({3,1,2}), 1)
    h.eq(L.max({3,1,2}), 3)
    h.eq(L.min({}), nil)
  end)
  h.it("range/reverse/take/drop/concat", function()
    h.eq(L.range(1, 4), {1,2,3,4})
    h.eq(L.reverse({1,2,3}), {3,2,1})
    h.eq(L.take({1,2,3,4}, 2), {1,2})
    h.eq(L.take({1,2}, 5), {1,2})
    h.eq(L.drop({1,2,3,4}, 2), {3,4})
    h.eq(L.concat({1,2}, {3,4}), {1,2,3,4})
  end)
  h.it("sort/sort_by (immutable)", function()
    local input = {3,1,2}
    h.eq(L.sort(input), {1,2,3})
    h.eq(input, {3,1,2})            -- input not mutated
    h.eq(L.sort_by({3,1,2}, function(a,b) return a > b end), {3,2,1})
  end)
  h.it("each runs side effects and returns nil", function()
    local seen = {}
    local r = L.each({1,2,3}, function(x) seen[#seen+1] = x end)
    h.eq(seen, {1,2,3})
    h.eq(r, nil)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `module 'std.list' not found` (the `.egg` doesn't exist yet).

- [ ] **Step 3: Implement `std/list.egg`** (functions ordered so dependencies precede dependents)

```
-- std/list.egg — list / array operations (collection-first, immutable)

pub let length xs = #xs
pub let is_empty xs = #xs == 0
pub let first xs = xs[1]
pub let last xs = xs[#xs]
pub let get xs i = xs[i]
pub let map xs f = [ f(x) | x <- xs ]
pub let filter xs pred = [ x | x <- xs, pred(x) ]
pub let range a b = [a to b]
pub let reverse xs = [ xs[#xs - i + 1] | i <- [1 to #xs] ]

let reduce_go xs f acc i =
  if i > #xs then acc
  else reduce_go(xs, f, f(acc, xs[i]), i + 1)
pub let reduce xs f init = reduce_go(xs, f, init, 1)

pub let each xs f =
  let _drop = [ f(x) | x <- xs ]
  nil

pub let sum xs = reduce(xs, fn a b -> a + b, 0)
pub let product xs = reduce(xs, fn a b -> a * b, 1)
pub let all xs pred = reduce(xs, fn acc x -> acc and pred(x), true)
pub let any xs pred = reduce(xs, fn acc x -> acc or pred(x), false)
pub let count xs pred = reduce(xs, fn acc x -> if pred(x) then acc + 1 else acc, 0)

pub let min xs =
  if is_empty(xs) then nil
  else reduce(xs, fn a b -> if a < b then a else b, first(xs))
pub let max xs =
  if is_empty(xs) then nil
  else reduce(xs, fn a b -> if a > b then a else b, first(xs))

let find_go xs pred i =
  if i > #xs then nil
  else if pred(xs[i]) then xs[i]
  else find_go(xs, pred, i + 1)
pub let find xs pred = find_go(xs, pred, 1)

pub let contains xs v = any(xs, fn x -> x == v)

let index_of_go xs v i =
  if i > #xs then nil
  else if xs[i] == v then i
  else index_of_go(xs, v, i + 1)
pub let index_of xs v = index_of_go(xs, v, 1)

pub let take xs n = [ xs[i] | i <- [1 to n], i <= #xs ]
pub let drop xs n = [ xs[i] | i <- [(n + 1) to #xs] ]

let concat_pick a b i = if i <= #a then a[i] else b[i - #a]
pub let concat a b = [ concat_pick(a, b, i) | i <- [1 to (#a + #b)] ]

pub let sort xs =
  let c = [ x | x <- xs ]
  let _drop = table.sort(c)
  c
pub let sort_by xs cmp =
  let c = [ x | x <- xs ]
  let _drop = table.sort(c, cmp)
  c
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — all `std.list` behavioral tests green; all prior tests still green. (If a function fails, the `.egg` line or its test pins the bug — fix the Omelette source.)

- [ ] **Step 5: Commit**

```bash
git add std/list.egg spec/list_spec.lua
git commit -m "feat: std.list module"
```

---

### Task 3: String module (`std/string.egg`)

**Depends on:** Task 1. **Independent of Tasks 2, 4.**

**Files:**
- Create: `std/string.egg`
- Create: `spec/string_spec.lua`

**Interfaces:**
- Produces a Lua module `std.string`. `split`/`replace` use literal (plain) matching.

- [ ] **Step 1: Write the failing behavioral test**

`spec/string_spec.lua`:
```lua
local h = require("spec.support.harness")
require("omelette.searcher").install()
local S = require("std.string")

h.describe("std.string", function()
  h.it("length/case", function()
    h.eq(S.length("hello"), 5)
    h.eq(S.upper("abc"), "ABC")
    h.eq(S.lower("ABC"), "abc")
  end)
  h.it("trim", function()
    h.eq(S.trim("  hi  "), "hi")
    h.eq(S.trim("nochange"), "nochange")
  end)
  h.it("starts_with/ends_with/contains", function()
    h.truthy(S.starts_with("hello", "he"))
    h.truthy(not S.starts_with("hello", "lo"))
    h.truthy(S.ends_with("hello", "lo"))
    h.truthy(S.contains("hello", "ell"))
    h.truthy(not S.contains("hello", "xyz"))
  end)
  h.it("split/join", function()
    h.eq(S.split("a,b,c", ","), {"a", "b", "c"})
    h.eq(S.split("nosep", ","), {"nosep"})
    h.eq(S.join({"a", "b", "c"}, "-"), "a-b-c")
  end)
  h.it("replace (literal)", function()
    h.eq(S.replace("a.b.c", ".", "-"), "a-b-c")
    h.eq(S.replace("aaa", "a", "bb"), "bbbbbb")
  end)
  h.it("rep", function()
    h.eq(S.rep("ab", 3), "ababab")
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `module 'std.string' not found`.

- [ ] **Step 3: Implement `std/string.egg`**

```
-- std/string.egg — string operations (thin wrappers + split/join/replace)

pub let length s = #s
pub let upper s = string.upper(s)
pub let lower s = string.lower(s)

pub let trim s =
  let r = string.gsub(s, "^%s*(.-)%s*$", "%1")
  r

pub let starts_with s prefix = string.sub(s, 1, #prefix) == prefix
pub let ends_with s suffix = string.sub(s, #s - #suffix + 1) == suffix
pub let contains s sub = string.find(s, sub, 1, true) ~= nil
pub let rep s n = string.rep(s, n)
pub let join xs sep = table.concat(xs, sep)

let append_pick xs x i = if i <= #xs then xs[i] else x
let append xs x = [ append_pick(xs, x, i) | i <- [1 to (#xs + 1)] ]

let split_go s sep acc start =
  let idx = string.find(s, sep, start, true)
  if idx == nil then append(acc, string.sub(s, start))
  else split_go(s, sep, append(acc, string.sub(s, start, idx - 1)), idx + #sep)
pub let split s sep = split_go(s, sep, [], 1)

pub let replace s old new = join(split(s, old), new)
```

Note: `let r = string.gsub(...)` truncates Lua's two return values to the result string. `split` requires a non-empty `sep`. `replace` is defined via `split` + `join` to avoid Lua pattern escaping.

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — `std.string` tests green; prior tests green.

- [ ] **Step 5: Commit**

```bash
git add std/string.egg spec/string_spec.lua
git commit -m "feat: std.string module"
```

---

### Task 4: Table module (`std/table.egg`)

**Depends on:** Task 1. **Independent of Tasks 2, 3.**

**Files:**
- Create: `std/table.egg`
- Create: `spec/table_spec.lua`

**Interfaces:**
- Produces a Lua module `std.table`. `keys`/`values` use key/value comprehension generators; `pairs` order is unspecified, so tests sort before comparing.

- [ ] **Step 1: Write the failing behavioral test**

`spec/table_spec.lua`:
```lua
local h = require("spec.support.harness")
require("omelette.searcher").install()
local T = require("std.table")

h.describe("std.table", function()
  h.it("keys/values (order-insensitive)", function()
    local ks = T.keys({ a = 1, b = 2 })
    local vs = T.values({ a = 1, b = 2 })
    table.sort(ks)
    table.sort(vs)
    h.eq(ks, { "a", "b" })
    h.eq(vs, { 1, 2 })
  end)
  h.it("get/has", function()
    h.eq(T.get({ x = 5 }, "x"), 5)
    h.truthy(T.has({ x = 5 }, "x"))
    h.truthy(not T.has({ x = 5 }, "y"))
  end)
  h.it("size", function()
    h.eq(T.size({ a = 1, b = 2, c = 3 }), 3)
    h.eq(T.size({}), 0)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `module 'std.table' not found`.

- [ ] **Step 3: Implement `std/table.egg`**

```
-- std/table.egg — dict / record operations

pub let keys d = [ k | k, v <- d ]
pub let values d = [ v | k, v <- d ]
pub let get d k = d[k]
pub let has d k = d[k] ~= nil
pub let size d = #keys(d)
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — `std.table` tests green; prior tests green.

- [ ] **Step 5: Commit**

```bash
git add std/table.egg spec/table_spec.lua
git commit -m "feat: std.table module"
```

---

## Self-Review

**1. Spec coverage:**
- Codegen change (locals + `M` alias; pub recursion/cross-ref) → Task 1 (golden + behavioral recursion test). ✓
- Module layout / `require` via searcher (default `./?.egg` root) → Tasks 2–4 test setup. ✓
- Collection-first + immutable + `nil`-for-absence → all module functions; `sort` immutability test asserts input unchanged. ✓
- List inventory (length, is_empty, first, last, get, map, filter, each, reduce, sum, product, min, max, all, any, find, contains, index_of, count, range, reverse, take, drop, concat, sort, sort_by) → Task 2. ✓
- String inventory (length, upper, lower, trim, starts_with, ends_with, contains, split, join, replace, rep) → Task 3. ✓
- Table inventory (keys, values, get, has, size) → Task 4. ✓
- Interop only `table.sort`/`string.*`/`table.concat` → Tasks 2–4. ✓
- `merge` deferred → not present (correct; in DEFERRED.md). ✓
- Dependency ordering within modules → functions ordered deps-first (noted). ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". Each module gives complete `.egg` source; each spec gives full assertions. The golden-test step says "run to confirm exact output, then pin it" for the few string-pattern assertions — these are `:find` substring checks, not brittle full-string golden, so they're robust. ✓

**3. Type consistency:** All module functions are collection-first; tests call them collection-first. The codegen change in Task 1 is what makes the cross-references in Tasks 2–4 (`sum`→`reduce`, `contains`→`any`, `size`→`keys`, `replace`→`split`/`join`, recursive `*_go` helpers) resolve — Tasks 2–4 depend on Task 1. Within each module, dependencies precede dependents (e.g. `reduce` before `sum`, `any` before `contains`, `split`/`join` before `replace`, `keys` before `size`). ✓
