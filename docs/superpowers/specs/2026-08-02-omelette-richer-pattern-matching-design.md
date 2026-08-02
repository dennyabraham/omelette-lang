# Omelette — Richer Pattern Matching Design

**Date:** 2026-08-02
**Status:** Approved design, pre-implementation
**Depends on:** v1 `match` (literal + wildcard), optional typing (for the checker touch)

## Summary

Extend `match` from literal/wildcard-only to real pattern matching: **variable-binding
patterns, array & record destructuring (with rename and nesting), and guards**. A whole
`match` now compiles to a **self-contained IIFE**, which cleanly supports bindings + guards
+ fall-through and — as a bonus — makes `match` a **first-class expression** usable in any
position (closing a deferred item). A non-exhaustive match with no matching value raises a
runtime error.

ADT/constructor patterns and compile-time exhaustiveness are **out of scope** (they need
sum types — a separate future cycle).

## Goals

- `| n ->` binds `n`; `| [a, b] ->` and `| { x, y } ->` destructure; `| p when c ->` guards.
- Fixes the current rough edge where a non-`_` identifier in pattern position errored.
- `match` works in any expression position (IIFE lowering).
- No-match fails loud (`error("match: no matching case")`) rather than silently yielding nil.

## Non-Goals (deferred)

- **ADT / constructor patterns** and **compile-time exhaustiveness** — need sum types.
- **Or-patterns** (`| 0 | 1 ->`) and **as-patterns** (`x as [a,b]`) — later.
- Type *inference* of bound variables — cycle-1 typing treats bound vars as `any`.

## Decisions

| Decision | Choice |
|---|---|
| Pattern kinds | literal, wildcard `_`, **variable**, **array `[…]`**, **record `{…}`**, + **guards** |
| Record syntax | **punning + rename**: `{ x, y: b }` (pun binds `x` from `.x`; `y: p` binds via sub-pattern `p` from `.y`) |
| Guard syntax | `| pattern when <expr> -> body` (new `when` keyword) |
| No-match behavior | **runtime error** `error("match: no matching case")` (dynamic-language norm; keeps match's static type honest) |
| Codegen | **IIFE** per match (also makes match a first-class expression) |
| Record match test | tests `type(subj)=="table"` only; fields bind (nil if absent) — destructuring semantics |

## Pattern Syntax & Semantics

```
match v with
| 0                  -> "zero"       -- literal (existing)
| _                  -> "other"      -- wildcard (existing)
| n                  -> n * 2        -- variable: always matches, binds n = v
| [a, b]             -> a + b        -- array: v is a table of length 2; binds a=v[1], b=v[2]
| [first, _]         -> first        -- nested wildcard
| { x, y }           -> x + y        -- record pun: binds x=v.x, y=v.y
| { x, y: b }        -> b            -- record rename: binds x=v.x, b=v.y
| [a, [b, c]]        -> b            -- nested array
| x when x > 10      -> "big"        -- guard
```

Semantics:
- **Variable** `name` always matches and binds `name` to the accessed value.
- **Array** `[p1..pn]` matches a table of **exactly** length `n`, recursively matching each
  element `pᵢ` against `subj[i]`.
- **Record** `{ f, g: p }` matches any **table**; each field binds its accessed value
  (`f` → `subj.f` bound to local `f`; `g: p` → sub-pattern `p` matched against `subj.g`).
  (No key-presence test in this cut — Lua/JS-style destructuring; absent fields bind nil.)
- **Nested** patterns compose to any depth.
- **Guard** `when <expr>`: after the pattern binds, the arm matches only if the boolean
  guard (which may reference bound variables) is truthy; otherwise fall to the next arm.
- **First matching arm wins**, top to bottom.
- **No arm matches → runtime error.**

## Parser

Replace the inline pattern logic in `Parser:parse_match` with a `Parser:parse_pattern()`:
- `_` (punct) → `{kind="wildcard"}`.
- number / string / `true` / `false` / `nil` → `{kind="lit", value, lit_kind}` (existing shape).
- bare **ident** (non-keyword) → `{kind="var", name}`.
- `[` → `{kind="array_pat", elems={<pattern>...}}` (comma-separated, until `]`).
- `{` → `{kind="record_pat", fields={{key=<string>, pat=<pattern>}...}}`. Each field: an
  `ident`; if followed by `:` then a sub-`parse_pattern` (rename/nest), else a pun
  (`pat = {kind="var", name=key}`).
- After the pattern, optional `when <expr>` → the case's `guard`. New `when` keyword.

Each case: `{ pattern = <pattern>, guard = <expr>|nil, body = <expr> }`. The existing
"needs at least one `|` case" error is preserved.

**Lexer:** add `when` to `KEYWORDS`. (`:` already exists from optional typing; `[` `]` `{` `}`
`|` are existing punct.)

## Codegen — match as an IIFE

A whole `match` compiles to a self-contained function (like comprehensions/ranges):

```lua
(function()
  local <subj> = <subject-expr>
  -- for each case, in order:
  if <structural tests> then
    local <bindings>
    if <guard-or-true> then return <body> end
  end
  -- …
  error("match: no matching case")
end)()
```

- `<subj>` is a fresh gensym (reuse the `ctx.acc` counter, e.g. `__m<n>`), so the subject is
  evaluated **once**.
- **`compile_pattern(pat, access, ctx) -> tests[], binds[]`** where `access` is a Lua
  expression string:
  - `wildcard` → `{}, {}`.
  - `lit` → `{ access .. " == " .. <lit-lua> }, {}`.
  - `var` → `{}, { {name, access} }` (binds `local name = access`).
  - `array_pat` → tests `type(access)==\"table\"` and `#access == <n>`; then for each element
    `i`, recurse against `access .. "[" .. i .. "]"`, appending its tests and binds.
  - `record_pat` → test `type(access)==\"table\"`; for each field, recurse the sub-pattern
    against `access .. "." .. key`, appending.
- Per case: emit `if <tests joined by " and " (or "true" if none)> then` then the `local`
  bindings, then (if a guard) `if <guard-expr> then return <body> end` else `return <body>`,
  then `end`. If there are no tests at all (e.g. a lone `var`/`_` with no guard), the case is
  an unconditional `return <body>` — subsequent cases become dead (acceptable; matches
  first-arm-wins).
- The body is emitted in return position via the existing `gen_fn_body` (so bodies that are
  `if`/`match`/`block` lower correctly).
- Trailing `error("match: no matching case")`.

**Wiring:** add a `match` case to `codegen.expr` returning the IIFE (so match is a first-class
expression). `gen_value`'s existing special `match` branch collapses to
`target = <M.expr(match-node)>` (or is removed, letting the generic simple-expression path
handle it). This removes the old flat `if/elseif` match lowering and the wildcard-only
codegen bug along with it.

## Typecheck

In `omelette/typecheck.lua`, the `match` synth walk (currently: synth subject, join case body
types) extends to:
- For each case, create a child scope; **bind each pattern variable as `any`** (walk the
  pattern collecting `var` names, incl. nested/record); synth the guard (if any) in that scope;
  synth the body in that scope.
- Join case body types as today (→ common type or `any`). No false positives; bound vars are
  `any`.

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), existing harness.

- **Lexer:** `when` is a keyword.
- **Parser:** variable / array / record (pun + rename) / nested / literal+wildcard (regression)
  patterns → correct AST; a guard attaches `guard`; empty-match error preserved.
- **Codegen golden:** the match-IIFE shape for a representative case (tests, bindings, guard,
  trailing `error`).
- **Behavioral (compile + run):**
  - variable binding (`| n -> n * 2`);
  - literal + wildcard regression unchanged;
  - array destructuring + length discrimination (`[a]` vs `[a, b]`);
  - record pun and rename;
  - nested (`[a, [b, c]]`, record with sub-patterns);
  - guard (matching and falling-through-on-false-guard);
  - **no-match raises** `match: no matching case`;
  - **match-as-expression:** a `match` used directly as a call argument / pipe LHS.
- **Typecheck:** pattern bindings + guards → no false positives; a real mismatch elsewhere
  still caught.

## File Touchpoints

- `omelette/lexer.lua` — add `when` keyword.
- `omelette/parser.lua` — `parse_pattern`; rewrite `parse_match` (guards); new pattern AST nodes.
- `omelette/codegen.lua` — `compile_pattern`; `gen_match` IIFE; `match` case in `expr`; collapse
  `gen_value`'s match branch.
- `omelette/typecheck.lua` — bind pattern variables (as `any`) + synth guards in `match`.
- `spec/` — lexer, parser, codegen-golden, behavioral, and typecheck tests.

No changes to compiler, resolver, CLI, REPL, or searcher.

## Deferred (record in `docs/DEFERRED.md`)

- ADT/constructor patterns + compile-time exhaustiveness (sum-types cycle) — the runtime
  error becomes the fallback the checker still permits.
- Or-patterns, as-patterns, key-presence testing for record patterns, and inference of bound
  variable types.
