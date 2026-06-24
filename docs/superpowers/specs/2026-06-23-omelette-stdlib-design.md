# Omelette — Standard Library Design

**Date:** 2026-06-23
**Status:** Approved design, pre-implementation
**Depends on:** v1, comprehensions, indexing/length, range + key/value generators

## Summary

A small standard library — **List**, **String**, **Table** — written **in Omelette**
itself, distributed as `std/*.egg` modules loaded via `require`. It rides on every
language feature built so far (comprehensions, `[a to b]`, `xs[i]`, `#xs`, tail
recursion) plus one small enabling codegen change so functions can reference each other
and recurse by name.

## Goals

- Practical List / String / Table modules covering the common functional operations.
- Written in Omelette (dogfooding); only the irreducible interop points touch Lua
  (`table.sort`, `string.*`, `table.concat`).
- `require("std.list")` etc. work via the existing searcher; modules are ordinary Lua
  modules, consumable from plain Lua too.

## Non-Goals (this cut)

- **`merge`** and any map-producing dict construction (needs map comprehensions —
  deferred, see `docs/DEFERRED.md`).
- **`_in_place` mutating variants** — the mixed-mutability convention is reserved (a
  `name_in_place` suffix), but v1 ships **all-immutable**; in-place variants are deferred
  until a measured need.
- No new syntax; this is a library plus one codegen refinement.

## Enabling Codegen Change — functions as locals + `M` alias

**Problem:** `pub let f x = …` currently compiles to `function M.f(x) … end`. A sibling
function referencing `f` by bare name compiles to a global lookup, not `M.f`, so
cross-references and self-recursion of public functions fail. The stdlib needs both
pervasively (`sum` calls `reduce`, recursive folds call themselves).

**Change:** emit every top-level binding as a **local**, and additionally assign it onto
`M` when `pub`:

| Omelette | Before | After |
|---|---|---|
| `let f x = …` | `local function f(x) … end` | `local function f(x) … end` (unchanged) |
| `pub let f x = …` | `function M.f(x) … end` | `local function f(x) … end` + `M.f = f` |
| `let x = e` | `local x = e` | `local x = e` (unchanged) |
| `pub let x = e` | `M.x = e` | `local x = e` + `M.x = x` |
| `pub let x = <if/match/block/comprehension/range>` | temp + `M.x = temp` | `local x`, lower into `x`, then `M.x = x` |

Because every binding becomes a module-level local, every function closes over its
siblings as upvalues — so `pub let sum xs = reduce(xs, …)` and recursive `pub` functions
resolve correctly. This also **closes the deferred "pub recursion-by-name" item**.

**Test impact:** the existing `spec/codegen_module_spec.lua` golden strings change
(`function M.add` → `local function add … M.add = add`); update them. Behavioral tests
(`compiler_spec`, etc.) are unaffected — `M.f` remains callable. Add a behavioral test
for a `pub` function that recurses by name.

## Module Layout & Access

- Source: `std/list.egg`, `std/string.egg`, `std/table.egg`.
- Loaded via the existing searcher: `require("std.list")` resolves `std/list.egg` on the
  searcher roots (`./?.egg`), compiled on demand. Tests call `searcher.install()` (or
  `require("omelette").install()`), set cwd to the repo root, then `require("std.list")`.
- Distribution: the rockspec lists the `std/*` modules (precompiled to `.lua` at build,
  or shipped as `.egg` with the searcher — the rockspec/build cycle decides; out of scope
  here).
- Each module is a normal `local M = {} … return M`, so plain Lua can `require` it too.

## Conventions

- **Collection-first arguments:** every operation takes the collection as the first
  argument, so pipes thread: `nums |> list.map(double) |> list.sum`.
- **Immutable:** operations return new tables; inputs are never mutated. `sort` copies
  (via a comprehension) then `table.sort`es the copy.
- **`nil` for absence:** `find`/`first`/`last`/`min`/`max` return `nil` when there is no
  result (Lua-idiomatic; no Option type — sum types are deferred).
- Functions are written as Omelette `let`/`pub let`; conditional element logic (e.g.
  `concat`) uses small helper functions whose `if`-bodies are valid (function bodies
  support `if`).

## Function Inventory

Signatures use `xs` (array), `d` (dict/record), `s` (string), `f`/`pred`/`cmp`
(functions). All collection-first.

### List (`std/list.egg`)
| Function | Semantics |
|---|---|
| `length(xs)` | `#xs` |
| `is_empty(xs)` | `#xs == 0` |
| `first(xs)` | `xs[1]` or `nil` |
| `last(xs)` | `xs[#xs]` or `nil` |
| `get(xs, i)` | `xs[i]` |
| `map(xs, f)` | `[ f(x) | x <- xs ]` |
| `filter(xs, pred)` | `[ x | x <- xs, pred(x) ]` |
| `each(xs, f)` | apply `f` to each element for side effects; returns `nil` |
| `reduce(xs, f, init)` | left fold; tail-recursive over `xs[i]` |
| `sum(xs)` | `reduce` with `+`, init `0` |
| `product(xs)` | `reduce` with `*`, init `1` |
| `min(xs)` / `max(xs)` | smallest / largest, `nil` if empty |
| `all(xs, pred)` / `any(xs, pred)` | universal / existential |
| `find(xs, pred)` | first element satisfying `pred`, or `nil` |
| `contains(xs, v)` | `true` if some element `== v` |
| `index_of(xs, v)` | 1-based index of first `== v`, or `nil` |
| `count(xs, pred)` | number of elements satisfying `pred` |
| `range(a, b)` | `[a to b]` |
| `reverse(xs)` | reversed copy (`[ xs[#xs - i + 1] | i <- [1 to #xs] ]`) |
| `take(xs, n)` | first `min(n, #xs)` elements |
| `drop(xs, n)` | all but the first `n` elements |
| `concat(a, b)` | elements of `a` then `b` (helper picks per index) |
| `sort(xs)` | ascending copy (comprehension-copy + `table.sort`) |
| `sort_by(xs, cmp)` | copy sorted by comparator `cmp(a, b) -> bool` |

### String (`std/string.egg`)
| Function | Semantics |
|---|---|
| `length(s)` | `#s` |
| `upper(s)` / `lower(s)` | `string.upper` / `string.lower` |
| `trim(s)` | strip leading/trailing whitespace (`string.gsub` with `^%s*(.-)%s*$`) |
| `starts_with(s, prefix)` | `string.sub(s, 1, #prefix) == prefix` |
| `ends_with(s, suffix)` | suffix compare via `string.sub` |
| `contains(s, sub)` | `string.find(s, sub, 1, true) ~= nil` (plain, not pattern) |
| `split(s, sep)` | array of substrings split on literal `sep` |
| `join(xs, sep)` | `table.concat(xs, sep)` |
| `replace(s, old, new)` | replace all literal `old` with `new` |
| `rep(s, n)` | `string.rep(s, n)` *(named `rep`, not `repeat` — Lua keyword)* |

### Table (`std/table.egg`)
| Function | Semantics |
|---|---|
| `keys(d)` | `[ k | k, v <- d ]` |
| `values(d)` | `[ v | k, v <- d ]` |
| `get(d, k)` | `d[k]` |
| `has(d, k)` | `d[k] ~= nil` |
| `size(d)` | number of key/value pairs (`#keys(d)`) |

## Implementation Notes

- **Interop is minimal and explicit:** `table.sort` (sort/sort_by), `string.*`
  (String module), `table.concat` (join). All are plain Lua globals called via Omelette's
  field-call interop.
- **`sort` immutability:** `let c = [ x | x <- xs ]` (copy), `let _drop = table.sort(c)`
  (mutates copy, returns nil bound to a throwaway local), result `c`. The block form
  (`let`s then result) sequences the side effect before returning the sorted copy.
- **`split`/`replace`** use literal (plain) matching, escaping Lua pattern magic where
  needed, so they behave as string operations, not regex.
- Functions that build on others (`sum`→`reduce`, `size`→`keys`) rely on the codegen
  change above (sibling upvalue references).

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), existing harness:

- **Codegen change:** update `spec/codegen_module_spec.lua` golden strings to the new
  `local function … M.f = f` shape; add a behavioral test for a `pub` recursive function
  (e.g. a factorial) and a `pub` function calling another `pub` function.
- **Per module (behavioral):** a spec file per module that installs the searcher,
  `require`s the module, and asserts results for each function — e.g. `list.map`,
  `list.reduce`/`sum`, `list.reverse`, `list.sort`, `list.take`/`drop`/`concat`,
  `string.split`/`join`/`trim`/`starts_with`, `table.keys`/`values`/`size`. Sort
  `keys`/`values` results before comparing (`pairs` order is unspecified).
- Edge cases: empty list (`sum []` → 0, `min []` → nil, `reverse []` → {}), `find` miss
  → nil, `take(xs, n)` with `n > #xs`.

## File Touchpoints

- `omelette/codegen.lua` — emit top-level bindings as locals + `M` alias for `pub`.
- `std/list.egg`, `std/string.egg`, `std/table.egg` — the modules.
- `spec/codegen_module_spec.lua` — updated golden strings + recursion test.
- `spec/list_spec.lua`, `spec/string_spec.lua`, `spec/table_spec.lua` — behavioral tests
  (install searcher, require, assert).

No changes to lexer, parser, compiler, resolver, CLI, or REPL.
