# Omelette — List Comprehensions Design

**Date:** 2026-06-20
**Status:** Approved design, pre-implementation
**Depends on:** Omelette v1 (lexer/parser/codegen/compiler pipeline)

## Summary

Add **Haskell-style list comprehensions** to Omelette: `[ yield | qualifiers ]`,
supporting **multiple generators and boolean guards**. Comprehensions are the
immutable-friendly iteration primitive for the language (Omelette has no loops and
no mutable variables by design), and they unblock writing the forthcoming standard
library *in Omelette itself*.

The only new lexer token is `<-`; there are no new keywords. Each comprehension
compiles to a self-contained **IIFE** (immediately-invoked function expression), so it
is a valid Lua expression usable in any position, and slots into the existing pipeline
with changes confined to the `[` case of the parser and one new node in codegen.

## Motivation & Context

Omelette is expression-oriented and immutable: `let` is a single immutable binding,
and there is no `for`/`while`. An imperative loop would be near-useless without
mutable variables to accumulate into, and adding mutation would pull Omelette away
from its ML identity. Comprehensions provide iteration that **produces a new
collection** without surface mutation — the functional answer (as in Haskell/Elm),
and the foundation the standard library will be built on.

This is the first of the post-v1 roadmap: **comprehensions → standard library
(built on them) → examples → gradual typing**.

## Goals

- `[ expr | x <- xs ]` (map), `[ expr | x <- xs, guard ]` (filter), and any
  combination of multiple generators and guards.
- Comprehensions usable in **any expression position** (call arguments, pipes,
  bindings, nested inside other comprehensions).
- Generated Lua stays **Lua 5.1-safe** and readable.
- Surface semantics stay immutable; mutation is hidden in generated Lua.

## Non-Goals (this cut)

- Dict / key-value iteration (`k, v <- dict`) and map-producing comprehensions
  (`{ ... | ... }`) — deferred.
- Destructuring patterns in generators (only a single identifier binds per generator).
- Using the IIFE technique to make `if`/`match` work as sub-expressions (out of scope;
  applied only to comprehensions here).
- Lazy/streaming comprehensions — results are fully materialized arrays.

## Language Surface

Grammar: `[ <yield-expr> | <qualifier> ( , <qualifier> )* ]`

A **qualifier** is either:
- a **generator** `name <- source` — binds `name` to each *value* of the array
  `source`, in order; or
- a **guard** — any boolean expression, filtering at its position.

```
-- map
[ x * 2 | x <- nums ]

-- filter
[ x | x <- nums, x > 0 ]

-- map + filter
[ x * x | x <- nums, even(x) ]

-- multiple generators (cartesian, x outer); pairs are 2-element arrays (no tuples)
[ [x, y] | x <- xs, y <- ys ]

-- interleaved generators and guards; a guard sees variables bound to its left
[ [x, y] | x <- xs, x > 0, y <- ys, x + y < 10 ]
```

### Semantics

- **Generators nest left-to-right**: the leftmost generator is the outermost loop.
- **Guards filter at their position** and may reference any variable bound to their
  left in the qualifier list.
- A generator `source` is an **array** (sequence table), iterated by value, in order.
- The result is always a **new array**.
- Yield expression and sources are ordinary expressions, so comprehensions **nest**.
- **Omelette has no tuples**: a comprehension yielding a pair uses a 2-element array
  `[x, y]` (or a record `{ a = x, b = y }`).

### Validity

- A comprehension requires **at least one qualifier** and **at least one generator**
  (a comprehension with only guards is meaningless). Otherwise: a value-based
  diagnostic with line/col.

## Lexer Changes (`omelette/lexer.lua`)

- Add `<-` to the multi-char operator list (type `op`, value `"<-"`). It is matched
  greedily alongside the other 2-char operators (`<=`, `>=`, etc.); single `<`
  remains comparison.
- **No new keywords.**
- **Documented gotcha:** `x<-1` lexes as the binder `x <- 1`. Write `x < -1` (with a
  space) for "x less than negative 1" — the same class of edge case as `(-1)` in
  Style Z, inherited directly from Haskell.

## Parser Changes (`omelette/parser.lua`)

Only the `[` case in `parse_primary` changes:

1. Parse the first expression.
2. Peek the next token:
   - `]` → singleton array `[expr]` (unchanged).
   - `,` → array literal — continue as today.
   - `|` → **comprehension** (below).
3. Comprehension: consume `|`, then parse a comma-separated **qualifier list** until
   `]`. For each qualifier, use two-token lookahead:
   - `ident` followed by the `<-` op → a **generator**: consume `ident`, `<-`, then
     parse the `source` expression.
   - otherwise → a **guard**: parse any expression.
4. After the list, require `]`. Validate ≥1 qualifier and ≥1 generator, else
   diagnostic.

The two-token lookahead is unambiguous: a guard that begins with an identifier (e.g.
`even(x)`) has a non-`<-` token after the identifier.

### New AST nodes

```lua
{ kind = "comprehension", yield = <expr>, quals = { <qualifier>... }, line, col }
-- qualifier:
{ kind = "generator", name = <string>, source = <expr> }
{ kind = "guard", cond = <expr> }
```

The `[` disambiguation does not affect the existing `array` node, which is still
produced for literal lists.

## Codegen (`omelette/codegen.lua`)

A comprehension is handled directly in `codegen.expr` as a normal expression that
emits an **IIFE**, making it valid in any Lua expression position with no special
casing in the statement-lowering machinery.

Emission:
- Open `(function()`.
- `local <acc> = {}` where `<acc>` is a fresh gensym name from `ctx`. (Each IIFE is
  its own function scope, so lexical scoping already makes reuse correct; unique
  names are purely for readable, unambiguous generated output.)
- For each qualifier in order:
  - generator → `for _, <name> in ipairs(<source>) do`
  - guard → `if <cond> then`
- Innermost: `<acc>[#<acc> + 1] = <yield>`.
- Close each opened `for`/`if` with `end`, in reverse order.
- `return <acc>` then `end)()`.

Example:

```
-- omelette
let evens_squared = [ x * x | x <- nums, even(x) ]
```
```lua
-- compiled Lua
local evens_squared = (function()
  local __acc1 = {}
  for _, x in ipairs(nums) do
    if even(x) then
      __acc1[#__acc1 + 1] = (x * x)
    end
  end
  return __acc1
end)()
```

Multiple generators + interleaved guard:
```
-- [ [x, y] | x <- xs, x > 0, y <- ys ]
(function()
  local __acc1 = {}
  for _, x in ipairs(xs) do
    if (x > 0) then
      for _, y in ipairs(ys) do
        __acc1[#__acc1 + 1] = {x, y}
      end
    end
  end
  return __acc1
end)()
```

Notes:
- Loop variables use the user's names (lexically scoped inside the IIFE; outer
  locals are captured as upvalues).
- The gensym counter lives in the existing codegen `ctx`. (A fresh `ctx` field is
  added for this; the v1 hole-numbering used a local counter, so a comprehension
  accumulator counter is introduced here and threaded through `expr`.)
- 5.1-safe: only `ipairs`, `#`, function expression, and `for … do … end`.
- **Cost:** one closure allocation + call per comprehension evaluation — negligible
  for a functional language; the payoff is comprehensions work anywhere an
  expression is legal.

## Testing Strategy

Run under `luajit` (enforces compiler 5.1-compatibility), using the existing pure-Lua
harness. Three layers:

- **Parser unit tests:** AST shape for single generator, multiple generators,
  interleaved guards; `[` disambiguation (singleton vs array literal vs
  comprehension); error cases (no generator, missing `]`).
- **Codegen golden tests:** exact emitted IIFE string for map, filter, and
  multi-generator cases — pins loop/guard nesting and the `ipairs`/append structure.
- **Behavioral tests (primary):** compile + `load()` + run, asserting runtime values:
  - `[ x*2 | x <- [1,2,3] ]` → `{2,4,6}`
  - `[ x | x <- [1,2,3,4], even(x) ]` → `{2,4}`
  - multi-generator cartesian → correct pairs and length
  - **inline expression position**: `sum([ x*x | x <- xs ])` and a piped comprehension
    — proves the IIFE lets comprehensions act as call arguments
  - nested comprehension (a comprehension in the yield) → runs correctly and the
    distinct gensym accumulators keep the generated Lua readable
- **Lexer test:** `<-` tokenizes as one `op`; the `x < -1` spacing case.

## File Touchpoints

- `omelette/lexer.lua` — add `<-` op.
- `omelette/parser.lua` — comprehension branch in the `[` case; new AST nodes.
- `omelette/codegen.lua` — `comprehension` case in `expr` (IIFE emission); gensym
  counter in `ctx`.
- `spec/` — parser, codegen, behavioral, and lexer tests as above.

No changes to `compiler.lua`, `resolver.lua`, the CLI/REPL, or the searcher: the new
node flows through the existing pipeline unchanged.
