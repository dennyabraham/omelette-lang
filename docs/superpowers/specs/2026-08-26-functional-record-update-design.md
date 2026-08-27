# Omelette — Functional Record Update Design

**Date:** 2026-08-26
**Status:** Approved design, pre-implementation
**Roadmap item:** Now/Next — "Functional record update" (from the OCaml comparison).

## Summary

Add `{ base with field = v, … }` — copy a record and override named fields — to Omelette's
immutable surface. Omelette is immutable by default but today offers no ergonomic way to
change one field of a record; you rebuild the whole thing by hand. OCaml's
`{ r with x = v }` is the immutable-language answer. This is pure syntax + codegen — no
type-system change, output stays readable Lua 5.1.

```egg
let c  = Circle { radius = 3 }
let c2 = { c with radius = 5 }        -- Circle, radius now 5
let p2 = { pt with x = pt.x + 1 }     -- override may reference the original
```

## Goals

- `{ base with f = v, … }` produces a shallow copy of `base` with the listed fields
  overridden; `base` is unchanged (immutable).
- `base` is any expression (variable, call, indexing, field access).
- Works on any table value, so it updates sum-type values too — `{ shape with radius = 10 }`
  preserves `__tag = "Circle"`.
- Readable, dependency-free Lua output (no injected runtime helper).
- The base is evaluated exactly once.

## Non-Goals (deferred)

- **Nested field paths** — `{ r with a.b = v }`. (OCaml doesn't do this without lenses.)
- **Static field-existence / type checking** — types are erased; validating that `field`
  belongs to `base`'s record/variant type pairs with the future field-type-annotation work
  (roadmap: sum-type field annotations). This cycle is dynamic, like the rest of the surface.
- **Deep copy** — updates are shallow; nested tables are shared (standard functional update).
- **Removing fields / spread of another record** (`{ a with …b }`). Only overriding named
  fields of a single base.

## Surface & disambiguation

Inside `{ … }` the parser today distinguishes three forms:

1. empty — `{}` → empty table
2. record literal — `{ ident = …, … }` (detected by `ident` followed by `=`)
3. dict comprehension — `{ key => value | quals }`

The update form is `{ <expr> with field = v, … }`. It cannot collide with the above: a
record literal is detected by `ident` immediately followed by `=`, whereas the update form
has `<expr>` followed by the `with` keyword. After the record-literal check fails, the
parser parses an expression and branches on the following token:

- `with` → **functional update** (new)
- `=>` → dict comprehension (existing)
- otherwise → the existing "expected `=>`" error

`with` is already a lexer keyword (used by `match … with`); in expression position an
expression parse stops at it (it is not an operator), so `parse_expr()` returns the base and
leaves `with` as the next token. A base that itself contains `with` (an inner `match`) must
be parenthesized — `{ (match x with …) with f = v }` — which is the existing rule for
match-as-subexpression.

## AST

New node from the parser:

```
{ kind = "record_update",
  base   = <expr node>,
  fields = { { key = <string>, value = <expr node> }, … },  -- key is a bare ident
  line, col }
```

`fields` mirrors the `table` node's shape (`key` is a bare identifier string, guaranteed by
`expect("ident")`), so field keys are safe to emit as `.key` without escaping.

## Codegen

Lua has no copy-with-override literal, and `base`'s keys are not known statically, so a
shallow copy loop is required. Emit an **inline IIFE** — consistent with how `match` and
comprehensions already lower, and dependency-free (no runtime helper injected into modules,
preserving Omelette's erased/self-contained output):

```lua
-- { c with radius = 5 }  ⇒
(function(__base)
  local __new = {}
  for __k, __v in pairs(__base) do __new[__k] = __v end
  __new.radius = 5
  return __new
end)(c)
```

Multiple fields emit one `__new.<key> = <value>` line each, in source order. The base
expression is emitted once as the IIFE argument (evaluated once); override value expressions
are emitted in the enclosing scope (they may reference the original binding, e.g.
`__new.x = pt.x + 1`).

**Temp names.** Use `__base`, `__new`, `__k`, `__v` — generated locals scoped inside the
IIFE. Note the lexer *does* allow user identifiers to start with `_` (`[%a_]` then `[%w_]`),
so these are not reserved. This follows the established convention: the existing comprehension
and match lowerings already emit `__`-prefixed temps (`__acc`, `__m`, `__i`, `__p`) inside
their IIFEs and accept the same vanishingly-small collision risk. The only capture hazard is
an override expression that literally references `__base`/`__new`/`__k`/`__v`; the copy loop
itself references nothing from user scope. Consistent with the range lowering's `__i`, we do
not guard against a user naming a variable `__base`. (Nested updates are correct without a
counter: each inner IIFE's params/locals lexically shadow the outer's.)

**Prefix wrapping.** Add `record_update` to `PREFIX_NEEDS_PAREN` (alongside `table`,
`array`, `lambda`, `construct`) so a literal-base index/field/call stays valid Lua 5.1 —
`{ r with x = 1 }.field`, `{ r with … }[k]`, `({ r with … })(…)`.

**Rejected alternative.** A shared `__omelette_update(base, overrides)` runtime helper would
be terser at the call site but requires injecting the helper into every emitted module (or
the stdlib), which fights the byte-clean, dependency-free output. The IIFE keeps each
expression self-contained.

## Semantics

- **Shallow copy** via `pairs` — copies the base's own key/value pairs (array + hash parts),
  then applies overrides. Nested tables are shared references.
- **Immutable** — `base` is untouched; a new table is returned.
- **Sum-type values** — since the copy is structural, `{ circleValue with radius = 10 }`
  copies `__tag` too, yielding a same-tag value with the field changed. (No checker
  validation this cycle.)
- **Base evaluated once** — as the IIFE argument. Override expressions are whatever the user
  wrote (evaluated in order, in the enclosing scope).
- **Metatables** — Omelette records/variant values are plain tables (no metatables), so
  `pairs` copy is complete. (Documented assumption, not a runtime concern here.)

## Testing strategy

Behavioral specs (compile + eval), a new `spec/record_update_spec.lua`:

- single-field override returns a new record with the field changed;
- the original is unchanged (immutability);
- multiple-field override, applied in order;
- override expression referencing the original (`{ pt with x = pt.x + 1 }`);
- update on a sum-type value preserves `__tag` (`{ Circle{radius=3} with radius = 9 }` still
  matches the `Circle` arm);
- base evaluated exactly once (a counter via a lambda-with-side-effect, or a `lua` block);
- the emitted Lua `load()`s (no syntax error);
- literal-base composition — `{ r with x = 1 }.x` and `({ r with … })` in a larger
  expression — proving the `PREFIX_NEEDS_PAREN` entry.

Plus one `docs/guide.md` ` ```egg ` example (CI-verified via the doctest harness), in the
records/immutability area.

## File touchpoints

- **Modify:** `omelette/parser.lua` (the `{`-handling block → detect `with`, emit
  `record_update`); `omelette/codegen.lua` (new `record_update` case + `PREFIX_NEEDS_PAREN`).
- **Create:** `spec/record_update_spec.lua`.
- **Modify:** `docs/guide.md` (one verified example).
- **Unchanged:** lexer (`with` already a keyword), typecheck (dynamic this cycle), stdlib.

## Roadmap follow-ups (record in `docs/ROADMAP.md`)

- Static field-existence / type checking of the override against the base's record or variant
  type — pairs with sum-type field annotations.
- Mark "Functional record update" shipped in the roadmap's Shipped section on completion.
