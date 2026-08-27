# Omelette — Destructuring `let` Bindings Design

**Date:** 2026-08-26
**Status:** Approved design, pre-implementation
**Roadmap item:** Now/Next — "Destructuring `let` bindings" (from the OCaml comparison).

## Summary

Allow a `let` binding's left-hand side to be a **pattern** — `let { radius } = circle`,
`let [a, b] = pair`, nested — reusing the existing `match` pattern parser. It binds the
pattern's variables by direct, irrefutable extraction from the value, compiling to plain Lua
`local`s (no runtime shape test, no IIFE). Pure syntax + codegen; no type-system change.

```egg
let { radius } = circle              -- pun: binds radius
let { x: px, y: py } = point         -- rename (record patterns use `key: sub`)
let [a, b] = pair                    -- positional
let { center: { x, y } } = shape     -- nested
```

## Goals

- A `let` whose LHS begins with `{` or `[` binds via a pattern (record / array / nested),
  reusing `parse_pattern`.
- Extraction is **irrefutable** and direct: no runtime shape check, plain `local` bindings.
- The value is evaluated exactly once.
- Works at block scope and top level, including `pub` export of every bound name.

## Non-Goals (deferred)

- **Refutable patterns** — literal (`let 0 = …`) and constructor (`let Some { x } = opt`)
  patterns are rejected; they can fail, which is what `match` is for.
- **Tuple patterns** `(a, b)` — wait on the positional-constructors / tuples cycle (there is
  no tuple pattern kind yet).
- **Type annotations on a destructured binding** — `let { x }: T = …`.
- **Refutable `let … else`** fallback binding.
- **Array length checking** — array destructuring is positional (see Semantics).

## Surface & disambiguation

`parse_let` today reads a bare `name` after `let` (plus optional function params, optional
`: type`). The change: after `let` (and optional `pub`), if the next token is `{` or `[`,
parse a **pattern** (`parse_pattern`) as the binding target instead of a name; otherwise the
existing name/params path is unchanged.

This cannot collide with the existing forms: a plain value/function binding always begins
with an `ident` (`let x …`, `let f a b = …`), never `{`/`[`. Record/array *literals* only
appear on the right of `=`, so a leading `{`/`[` after `let` is unambiguously a pattern.

`parse_pattern` already yields: `record_pat` (`{ key }` pun → `var`; `{ key: sub }` rename /
nest), `array_pat` (`[p, …]`), `var`, `wildcard`, `lit`, `ctor_pat`. Destructuring `let`
accepts only the **irrefutable** subset — `var`, `wildcard`, `record_pat`, `array_pat`,
nested — and rejects `lit` / `ctor_pat`.

## Irrefutable-only rule

After parsing the LHS pattern, `parse_let` validates it is irrefutable: it walks the pattern
and fails (a parse error at the pattern's position) if any `lit` or `ctor_pat` node appears,
with a message directing the user to `match`:

> `a let pattern must always match; use 'match' for constructor/literal patterns`

Record and array patterns are irrefutable by fiat here (missing fields/elements bind `nil`,
see Semantics), so only `lit`/`ctor_pat` are refused.

## AST

A destructuring `let` reuses `kind = "let"` but carries `pattern` instead of `name`:

```
{ kind = "let", pattern = <pattern node>, value = <expr/block>,
  is_pub = <bool>, line, col }        -- no `name`, `params`, `param_types`, or type
```

Non-destructuring lets are unchanged (`name`, optional `params`, etc.). Codegen distinguishes
the two by the presence of `node.pattern`.

## Codegen

Two helpers in `codegen.lua`:

**`pattern_names(pattern)` → ordered list of bound variable names.** Walks the pattern
collecting `var` leaves (skipping `wildcard`); recurses into `record_pat.fields[].pat` and
`array_pat.elems[]`. Feeds the top-level forward-declaration and `pub` export.

**`gen_destructure(pattern, value_node, ctx, pad, decl)` → statements.** Binds the pattern's
variables by direct extraction. Field access and indexing are pure, so nesting just extends
the access path — no intermediate temps. A single temp holds the value only when it is not a
simple identifier (single-eval):

```lua
-- let { center: { x, y } } = shape        (shape is a var → no temp)
local x = shape.center.x
local y = shape.center.y

-- let { x, y } = getPoint()                (non-ident → one temp)
local __d = getPoint()
local x = __d.x
local y = __d.y

-- let [a, b] = pair                        (array → positional indices)
local a = pair[1]
local b = pair[2]
```

`decl = true` emits `local <name> = <access>` (block scope); `decl = false` emits
`<name> = <access>` (top level, where names are forward-declared). `wildcard` fields/elements
emit nothing. Recursion: `record_pat` field → access `.. "." .. key`; `array_pat` element i
→ access `.. "[" .. i .. "]"`.

Temp naming: `__d`, following the existing IIFE-temp convention (`__acc`, `__m`, `__i`). The
value temp is only read by generated extraction (never by user override expressions), and
`local __d = <value>` evaluates `<value>` in the outer scope, so a value expression that
itself references a user variable named `__d` is still correct.

### Integration points

- **`parse_let`** (`parser.lua`) — pattern LHS + irrefutable check.
- **`gen_local_let`** (`codegen.lua`) — if `node.pattern`, emit `gen_destructure(…, decl=true)`.
- **`gen_top_assign`** (`codegen.lua`) — if `node.pattern`, emit `gen_destructure(…, decl=false)`.
- **`M.program`** (`codegen.lua`) — the forward-declared `names` list appends
  `pattern_names(node.pattern)` for a destructuring let (instead of `node.name`); `pub` export
  emits `M.<name> = <name>` for each bound name.

## Semantics

- **Irrefutable extraction** — no runtime `type`/shape/length test. Record fields read
  `base.key`; array elements read `base[i]`. Missing fields/elements bind `nil` — consistent
  with Omelette's existing "absent record fields bind `nil`" rule.
- **Array is positional** — `let [a, b] = xs` reads `xs[1]`, `xs[2]`; a shorter `xs` binds
  `nil`, a longer one ignores the rest. Length-discrimination stays a `match` job.
- **Single evaluation** — the value is emitted once (directly if a bare identifier, else via
  one `__d` temp).
- **Nested** — record-in-record, array-in-record, record-in-array, etc., all recurse by
  extending the access path.
- **`pub`** — `pub let { x, y } = …` exports both `M.x` and `M.y`.
- **Top-level ordering** — bound names are forward-declared like every other top-level
  binding, so mutual reference / definition-order independence is preserved.

## Testing strategy

New `spec/destructure_let_spec.lua`, behavioral (`compiler.eval`) unless noted:

- record pun — `let { a } = { a = 1, b = 2 }` binds `a == 1`;
- record rename — `let { a: x } = { a = 1 }` binds `x == 1`;
- nested — `let { p: { x, y } } = { p = { x = 3, y = 4 } }` binds `x, y`;
- array positional — `let [a, b] = [10, 20, 30]` binds `a == 10, b == 20`;
- array shorter binds nil — `let [a, b] = [1]` → `b == nil`;
- wildcard skips — `let [a, _, c] = [1, 2, 3]` binds `a, c`, no binding for the hole;
- single-eval — a non-ident value's distinctive identifier appears exactly once in
  `compiler.compile` output;
- `pub` exports each name — `pub let { a, b } = …` → module has `a` and `b`;
- top-level mutual reference still works (a destructuring binding alongside functions);
- refutable rejected — `compiler.compile("let Some { x } = v")` and `let 0 = v` return the
  irrefutable-only error (assert via the diagnostic message);
- emitted Lua `load()`s.

Plus one `docs/guide.md` ` ```egg ` example (CI-verified via the doctest harness).

## File touchpoints

- **Modify:** `omelette/parser.lua` (`parse_let` — pattern LHS + irrefutable check);
  `omelette/codegen.lua` (`pattern_names`, `gen_destructure`, and the `node.pattern` branches
  in `gen_local_let` / `gen_top_assign` / `M.program`).
- **Create:** `spec/destructure_let_spec.lua`.
- **Modify:** `docs/guide.md` (one verified example).
- **Unchanged:** lexer, typecheck (dynamic this cycle), stdlib.

## Roadmap follow-ups (record in `docs/ROADMAP.md`)

- Tuple patterns in `let` once positional constructors / tuples land.
- Type annotations on destructured bindings (pairs with collection types).
- Mark "Destructuring let bindings" shipped in the roadmap's Shipped section on completion.
