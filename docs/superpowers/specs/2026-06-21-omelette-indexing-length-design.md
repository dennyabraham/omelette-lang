# Omelette — Indexing & Length Primitives Design

**Date:** 2026-06-21
**Status:** Approved design, pre-implementation
**Depends on:** Omelette v1 pipeline (lexer/parser/codegen)

## Summary

Add two small, fundamental language primitives to Omelette: **read indexing `xs[i]`**
and **length `#xs`**. Both mirror Lua exactly and compile to Lua 5.1 directly. They are
broadly useful on their own and specifically unblock the **fold family** of the upcoming
standard library (`reduce`, `sum`, `min`, `max`, `all`, `any`, `find`, etc.), which is
written in Omelette via tail recursion over indexed elements.

## Motivation & Context

Omelette has comprehensions (`map`/`filter`, list → list) but no way to read an element
by index or get a collection's length — so reductions (list → scalar) cannot be written
in Omelette. Indexing and length are the minimal primitives that close that gap. They are
also things any real program wants regardless of the stdlib. List-construction primitives
(`range`, array concat) and `sort` are intentionally **out of scope** here and will be
decided when the standard library itself is specced.

This is the first cycle of: **indexing+length → standard library → …**

## Goals

- `xs[i]` reads the element/field of a table at a computed key.
- `#xs` returns the length of a table (element count) or string (byte length).
- Both compile to idiomatic, Lua 5.1-safe code (`t[k]`, `#t`).
- The surface stays immutable (indexing is read-only; no `xs[i] = v`).

## Non-Goals (this cycle)

- **Index assignment** `xs[i] = v` — not added; the surface stays immutable.
- **String character indexing** via `s[i]` — Lua returns `nil` for `("abc")[1]`; character
  access is `string.sub`, which the String stdlib will use. `#s` (string length) *is* added.
- `range`/`[a..b]` literals, array concatenation `++`, and `sort` — deferred to the stdlib spec.
- Recursion-by-name for `pub let` functions — deferred (the local-impl + `pub` alias pattern works today).

## Language Surface

```
-- read indexing (tables/arrays); exactly one key expression
let first = xs[1]
let v     = record["key"]
let nested = grid[i][j]

-- length (tables and strings)
let n   = #xs
let len = #"hello"          -- 5

-- the two together enable folds via tail recursion, e.g.:
let sum_go xs acc i =
  if i > #xs then acc
  else sum_go(xs, acc + xs[i], i + 1)
let sum xs = sum_go(xs, 0, 1)
```

### Semantics

- `xs[i]` evaluates `xs` then the key, and reads `xs[key]` (Lua table indexing). Missing
  keys yield `nil`, as in Lua. Read-only — there is no assignment form.
- `#xs` is Lua's length operator: number of array elements for a sequence table, byte
  length for a string.
- `s[i]` on a string yields `nil` (Lua semantics) — not a supported character-access form.

## Lexer Changes (`omelette/lexer.lua`)

- Add `#` to the single-character operators (`SINGLE_OPS`), emitted as `{ type = "op",
  value = "#" }`. No conflict: comments are `--`, and `#` is otherwise unused.
- No new keywords. `[` and `]` are already punctuation tokens.

## Parser Changes (`omelette/parser.lua`)

- **Indexing — `parse_postfix`:** add a `[` branch alongside the existing `.field` and
  `(call)` handling. On `[`: consume `[`, parse exactly one expression as the key, expect
  `]`, and build `{ kind = "index", obj = node, key = <expr>, line, col }`. Because the
  language has no juxtaposition application, a `[` immediately following an expression is
  unambiguously an index; a `[` in primary position remains an array literal/comprehension.
- **Length — `parse_unary`:** add `#` (an `op` token) as a unary prefix operator
  alongside `-` and `not`, producing `{ kind = "unop", op = "#", operand = <expr> }`.
  `#` binds like the other unary operators (tighter than binary operators), so `#xs + 1`
  parses as `(#xs) + 1`.

### New / reused AST nodes

```lua
{ kind = "index", obj = <expr>, key = <expr>, line, col }   -- new
{ kind = "unop", op = "#", operand = <expr>, line, col }    -- reuses existing unop
```

## Codegen Changes (`omelette/codegen.lua`)

- **`index` case in `expr`:** `return expr(node.obj, ctx) .. "[" .. expr(node.key, ctx) .. "]"`.
  Produces `obj[key]`.
- **`unop` case:** extend the operator mapping so `#` emits `#` (currently it maps `not` →
  `"not "`, else `"-"`); the result is `(#x)`. Keep the parenthesization the existing unop
  uses.

Both emit core Lua 5.1 (`t[k]`, `#t`). No other codegen paths change; the `index` node, like
any expression, composes inside comprehensions, calls, pipes, and bindings via `expr`.

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), using the existing harness. Layers:

- **Lexer:** `#` tokenizes as `{ op, "#" }`.
- **Parser:** `xs[1]` → `index` node with `obj`/`key`; chained `grid[i][j]` nests `index`;
  `#xs` → `unop` with `op="#"`; the `f[1]` (index) vs `[1]` (array literal) disambiguation;
  error on a two-key index `xs[1, 2]`.
- **Codegen golden:** `xs[i]` → `xs[i]`; `record["key"]` → `record["key"]`; `#xs` → `(#xs)`.
- **Behavioral (compile + run):**
  - index into an array (`[10,20,30][2]` → `20`) and a record (`{a=1,b=2}["b"]` → `2`),
  - `#` of an array (`#[1,2,3]` → `3`) and a string (`#"hello"` → `5`),
  - a tail-recursive `sum` using `xs[i]` + `#xs` returns the correct total — proving the
    primitives enable folds.

## File Touchpoints

- `omelette/lexer.lua` — add `#` to single-char operators.
- `omelette/parser.lua` — `index` in `parse_postfix`; `#` in `parse_unary`.
- `omelette/codegen.lua` — `index` case in `expr`; `#` in the `unop` mapping.
- `spec/` — lexer, parser, codegen-golden, and behavioral tests as above.

No changes to `compiler.lua`, `resolver.lua`, the CLI/REPL, or the searcher.
