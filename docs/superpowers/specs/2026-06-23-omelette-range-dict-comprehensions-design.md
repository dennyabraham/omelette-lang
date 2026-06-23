# Omelette — Range Literals & Key/Value Comprehension Generators Design

**Date:** 2026-06-23
**Status:** Approved design, pre-implementation
**Depends on:** Omelette v1 + comprehensions + indexing/length

## Summary

Add two language features that unblock the list-construction and dict portions of the
upcoming standard library:

1. **Range literals — `[a to b]`** — an inclusive, ascending integer range (`[1 to 5]`
   → `{1,2,3,4,5}`).
2. **Key/value comprehension generators — `k, v <- dict`** — a comprehension generator
   that binds two names and iterates a table's pairs (vs the existing single-name form
   that iterates array values).

With these, the stdlib's list builders (`range`, `reverse`, `take`, `drop`, `slice`,
`concat`, `flatten`) become expressible in Omelette (range + indexing + helper
functions), and `keys`/`values` become expressible via key/value generators.

## Motivation & Context

Comprehensions gave us `map`/`filter`; indexing + length gave us the fold family. But
*constructing* a new list of computed size (no source to comprehend over, and indexing
is read-only) and iterating a *dict's* pairs both remained impossible. `range` is the
linchpin for list construction (`reverse = [ xs[#xs - i + 1] | i <- [1 to #xs] ]`), and
key/value generators are the linchpin for dict reads. This cycle adds exactly those two,
then the standard library follows.

## Goals

- `[a to b]` evaluates to a fresh array `{a, a+1, …, b}`; empty when `a > b`.
- A comprehension generator may bind one name (array values, `ipairs`) or two names
  (table pairs, `pairs`).
- Both compile to idiomatic, Lua 5.1-safe code and work in any expression position.

## Non-Goals (this cycle)

- **Descending ranges / custom step** (`[5 to 1]` is *empty*, not descending; no
  `[a, b .. c]` step form). Deferred.
- **Map-producing comprehensions** (`{ k => v | … }`) and therefore `merge` (building a
  *new* dict with dynamic keys). Deferred to a later feature; `get`/`has` already work
  via `xs[i]`.
- **`..` as a range operator** — `..` is string concat; the keyword `to` avoids the
  collision (see Decision below).
- Using `_` as a generator name (it lexes as `punct`, not `ident`); use a real name for
  the unused binding (e.g. `[ v | k, v <- d ]` with `k` unused).

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Range syntax | **`[a to b]`** (keyword `to`) | `..` is already string concat; `[1..5]` is already a valid singleton concat array. `to` avoids the collision, reads well, echoes `for i = 1 to n`. Cost: `to` is reserved. |
| Range bounds | **inclusive, ascending, step 1** | Simplest; matches Pascal/Haskell inclusive convention. `a > b` → empty (Lua numeric `for` semantics). |
| Dict generator | **`k, v <- dict`** (two names → `pairs`) | Single name stays `ipairs` (values); two names iterate pairs. |

## Feature 1 — Range literals `[a to b]`

### Surface

```
[1 to 5]          -- {1, 2, 3, 4, 5}
[1 to n]          -- {1, ..., n}
[5 to 1]          -- {} (empty; not descending)
[ x * x | x <- [1 to 3] ]   -- range feeding a comprehension → {1, 4, 9}
```

### Lexer (`omelette/lexer.lua`)
- Add `to` to the keyword set. No new operators.

### Parser (`omelette/parser.lua`)
- In the `[` branch of `parse_primary`, after parsing the first expression, the existing
  dispatch is: `]` → singleton/empty array, `,` → array literal, `|` → comprehension.
  Add: **`to` (keyword)** → range. Consume `to`, parse the end expression, expect `]`,
  build `{ kind = "range", from = <first>, to = <end>, line, col }`. (`to` is a keyword,
  so the first expression's parse stops before it.)

### Codegen (`omelette/codegen.lua`)
- New `range` case in `expr`, emitting a self-contained IIFE (valid in any position):
  ```lua
  (function()
    local <acc> = {}
    for __i = <from>, <to> do
      <acc>[#<acc> + 1] = __i
    end
    return <acc>
  end)()
  ```
  `<acc>` is `__acc<n>` from the existing `ctx.acc` counter; `__i` is a fixed loop
  variable (safe — each IIFE is its own scope). Lua's numeric `for` with default step 1
  yields an empty result when `from > to`. 5.1-safe.

## Feature 2 — Key/value comprehension generators `k, v <- dict`

### Surface

```
[ k | k, v <- d ]      -- keys of dict d
[ v | k, v <- d ]      -- values of dict d
[ x | x <- xs ]        -- unchanged: array values
```

### Parser (`omelette/parser.lua`)
- In the comprehension qualifier loop, extend generator detection. The generator AST node
  gains an optional second name:
  - `{ kind = "generator", name = <string>, value_name = nil, source }` (one name)
  - `{ kind = "generator", name = <string>, value_name = <string>, source }` (two names)
- Detection (lookahead on the qualifier's leading tokens):
  - `ident <-` → single-name generator.
  - `ident , ident <-` → two-name generator (first = `name`, second = `value_name`).
  - otherwise → guard (existing behavior).
  This needs up to four-token lookahead (`ident`, `,`, `ident`, `<-`); use the existing
  `peek`/`peek2` plus direct `self.toks[self.pos + n]` indexing.

### Codegen (`omelette/codegen.lua`)
- In the comprehension generator emission:
  - one name → `for _, <name> in ipairs(<source>) do` (unchanged)
  - two names → `for <name>, <value_name> in pairs(<source>) do`

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), existing harness. Layers:

- **Lexer:** `to` tokenizes as a keyword.
- **Parser:**
  - `[1 to 10]` → `range` node with `from`/`to`; the `[` dispatch still yields `array`
    for `[1,2]`/`[]`/`[1]` and `comprehension` for `[x | x <- xs]` (regression).
  - `[ k | k, v <- d ]` → generator with `name="k"`, `value_name="v"`; single-name
    generator still has `value_name = nil`.
- **Codegen golden:** range IIFE exact string; two-name generator emits `pairs(...)` and
  single-name still emits `ipairs(...)`.
- **Behavioral (compile + run):**
  - `[1 to 5]` → `{1,2,3,4,5}`; `[5 to 1]` → `{}` (empty); `[1 to n]` with a variable bound.
  - range feeding a comprehension: `[ x*x | x <- [1 to 3] ]` → `{1,4,9}`.
  - reverse via range: `[ xs[#xs - i + 1] | i <- [1 to #xs] ]` on `{10,20,30}` → `{30,20,10}`.
  - keys/values: on a record `{ a = 1, b = 2 }`, `[ k | k, v <- d ]` and `[ v | k, v <- d ]`
    return the keys / values (assert via set-membership or sorted compare, since `pairs`
    order is unspecified).

## File Touchpoints

- `omelette/lexer.lua` — add `to` keyword.
- `omelette/parser.lua` — `range` in the `[` branch; two-name generator detection.
- `omelette/codegen.lua` — `range` IIFE case; `pairs`/`ipairs` choice in comprehension
  generator emission (and the generator node's new `value_name` field).
- `spec/` — lexer, parser, codegen-golden, behavioral tests as above.

No changes to `compiler.lua`, `resolver.lua`, the CLI/REPL, or the searcher.
