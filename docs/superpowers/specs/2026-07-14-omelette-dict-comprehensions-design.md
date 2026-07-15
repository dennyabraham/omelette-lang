# Omelette — Dict Comprehensions & `merge` Design

**Date:** 2026-07-14
**Status:** Approved design, pre-implementation
**Depends on:** v1 + comprehensions + range + key/value generators + indexing/length

## Summary

Add **map-producing (dict) comprehensions** — `{ key => value | qualifiers }` — which build
a table with dynamic keys, mirroring the existing list comprehension. This unblocks the
standard library's `merge`, the last deferred stdlib function. The only new lexer token is
`=>`; the qualifier machinery (generators, including `k, v <- dict`, and guards) is shared
with list comprehensions.

## Goals

- `{ k => v | k, v <- d }` builds a dict; keys and values are arbitrary expressions.
- Works in any expression position (IIFE), Lua 5.1-safe.
- Add `merge(a, b)` to `std/table.egg`, self-contained (no cross-module require).

## Non-Goals

- Set comprehensions or other collection kinds.
- Changing record-literal syntax (`{ x = 1 }` is unchanged).

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Separator | **`=>`** | Records use `=`; `=>` reads "maps to"; keeps `:` free for gradual-typing annotations (#1). |
| Record vs dict-comp | two-token lookahead: `{ ident = …}` → record, else dict comp | Unambiguous — records are always `ident = …`, dict comps always have `… =>`. |
| `merge` impl | **self-contained** in `std/table.egg` (local helpers) | No load-time cross-module require; no coupling to `std.list`. |

## Feature 1 — Dict comprehensions `{ key => value | quals }`

### Surface

```
{ k => v | k, v <- d }               -- copy a dict
{ k => f(v) | k, v <- d }            -- map values
{ upper(k) => v | k, v <- d, v > 0 } -- transform keys + filter
{ i => i * i | i <- [1 to 3] }        -- build a dict from a list/range
```

### Lexer (`omelette/lexer.lua`)
- Add `=>` to the multi-char operator list (type `op`, value `"=>"`). No new keywords. (Matched
  greedily before single `=`; `x = 1` is unaffected since there's no `>` after `=`.)

### Parser (`omelette/parser.lua`)
- **Refactor:** extract the comprehension-qualifier parsing currently inline in the `[` branch
  into a shared method `Parser:parse_qualifiers()` (returns the `quals` list, requiring ≥1
  generator, using the existing single- and two-name generator detection and guard fallback).
  The `[` (list comprehension) branch calls it; the `{` branch reuses it.
- **`{` branch of `parse_primary`:** two-token lookahead after `{`:
  - `}` → empty record `{ }` (existing).
  - `ident` immediately followed by `=` (op) → **record literal** (existing `ident = expr` field
    parsing).
  - otherwise → **dict comprehension**: parse `key` expression, `expect("op", "=>")`, parse
    `value` expression, `expect("punct", "|")`, `parse_qualifiers()`, `expect("punct", "}")`.
- New AST node: `{ kind = "dict_comprehension", key = <expr>, value = <expr>, quals = {…}, line, col }`.

### Codegen (`omelette/codegen.lua`)
- New `dict_comprehension` case in `expr`, emitting an IIFE that mirrors `gen_comprehension`
  but assigns into a keyed table instead of appending:
  ```lua
  (function()
    local <acc> = {}
    for <gen> do            -- generators: `for k, v in pairs(src)` / `for _, x in ipairs(src)`
      if <guard> then       -- guards, in qualifier order
        <acc>[<key>] = <value>
      end
    end
    return <acc>
  end)()
  ```
  `<acc>` is a fresh `__acc<n>` from the shared `ctx.acc` counter. Factor the qualifier
  loop/nesting (generators → `for … pairs/ipairs`, guards → `if`) so `gen_comprehension` (list)
  and the dict version share it, differing only in the innermost line (`acc[#acc+1] = yield`
  vs `acc[key] = value`).

## Feature 2 — `std.table.merge`

Add to `std/table.egg` (self-contained; `keys`/`has` already exist in the module, defined
above `merge`; top-level mutual recursion means ordering is now flexible, but keep helpers
before `merge` for readability):

```
let pick a b k = if has(b, k) then b[k] else a[k]
let cc a b i = if i <= #a then a[i] else b[i - #a]
let allkeys a b = [ cc(a, b, i) | i <- [1 to (#a + #b)] ]
pub let merge a b = { k => pick(a, b, k) | k <- allkeys(keys(a), keys(b)) }
```

Semantics: the result has every key of `a` and `b`; on a key present in both, **`b` wins**
(`pick` prefers `b`). Duplicate keys in `allkeys` assign the same value twice — harmless.

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), existing harness.

- **Lexer:** `=>` tokenizes as one `op`; `x = 1` still lexes `=` then `1` (no false `=>`).
- **Parser:**
  - `{ k => v | k, v <- d }` → `dict_comprehension` node with `key`/`value`/`quals`.
  - Record regression: `{ x = 1, y = 2 }` → `table` node; `{}` → empty `table`.
  - Disambiguation: `{ k => v | … }` (key is an ident) is a dict comp, not a record.
- **Codegen golden:** the dict-comp IIFE with `__acc1[k] = …`; `pairs` for `k, v <-`, `ipairs`
  for single-name generators.
- **Behavioral (compile + run):**
  - copy: `{ k => v | k, v <- {a=1,b=2} }` deep-equals `{a=1,b=2}`.
  - map values: `{ k => v * 10 | k, v <- {a=1,b=2} }` → `{a=10,b=20}`.
  - filter: `{ k => v | k, v <- {a=1,b=2,c=3}, v > 1 }` → `{b=2,c=3}`.
  - build from a range: `{ i => i * i | i <- [1 to 3] }` → `{1,4,9}` as `{[1]=1,[2]=4,[3]=9}`.
  - **`merge`** (via `std.table`): overriding keys (`merge({a=1,b=2},{b=9,c=3})` → `{a=1,b=9,c=3}`)
    and disjoint keys. (Compare whole tables with the harness's deep-eq.)

## File Touchpoints

- `omelette/lexer.lua` — add `=>` op.
- `omelette/parser.lua` — extract `parse_qualifiers`; dict-comp branch in the `{` case; new node.
- `omelette/codegen.lua` — shared qualifier-loop helper; `dict_comprehension` IIFE case.
- `std/table.egg` — add `merge` (+ local helpers).
- `spec/` — lexer, parser, codegen-golden, and behavioral tests (incl. a `merge` test).

No changes to compiler, resolver, CLI, REPL, or searcher.
