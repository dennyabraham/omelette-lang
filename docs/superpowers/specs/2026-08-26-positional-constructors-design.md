# Omelette — Positional Constructors Design

**Date:** 2026-08-26
**Status:** Approved design, pre-implementation
**Roadmap item:** Now/Next — "Positional constructors + tuples" (split: this spec is positional
constructors; tuples are a separate follow-up cycle).

## Summary

Add positional-payload constructors to Omelette's sum types — `type Option = Some(a) | None`,
build `Some(3)`, match `Some(x)` — so a variant no longer must be a named record. Parens mean
positional, braces mean named (existing), bare means nullary; all three coexist in one type.
Positional payloads land in the Lua array part of the tagged-record rep. Extends the parser,
codegen, and the typecheck registry/validation. Runtime stays dynamic; output stays readable
Lua 5.1.

```egg
type Option = Some(a) | None
type Tree   = Leaf(value) | Node(left, right)

let rec size t =
  match t with
  | Leaf(_)    -> 1
  | Node(l, r) -> size(l) + size(r)
```

## Goals

- Declare positional constructors: `Ctor(slot, …)` (parens), coexisting with named
  `Ctor { field, … }` and nullary `Ctor` in the same `type`.
- Construct: `Ctor(arg, …)` builds `{ __tag = "Ctor", <args…> }` (args in the array part).
- Match: `Ctor(pat, …)` binds sub-patterns from the positional slots, full arity required.
- The checker validates construction/pattern **arity** and **named-vs-positional shape**;
  exhaustiveness is unchanged.

## Non-Goals (deferred / separate cycles)

- **Tuples** `(x, y)` and tuple patterns — the sibling follow-up spec.
- **Field types / generics** — the slot identifiers (`a`, `left`) are erased this cycle; only
  their count (arity) is used. Reserved for future field-type annotations and parametric
  variants (`Some(number)`, generic `a`).
- **Constructors as first-class function values** (`list.map(Some, xs)`) — construction stays
  inlined.
- **Mixed positional+named in one constructor** (`Ctor(a) { b }`) — a constructor is exactly
  one of positional / named / nullary.

## Declaration syntax & registry

`parse_type_decl` today reads, per variant, a `name` and a `fields` list (named idents, from a
`{ … }` block) — nullary when the block is absent. Add a **positional** form: after the
constructor name, if the next token is `(`, parse a comma-separated list of identifiers (the
positional slots) until `)`; the variant is positional with `arity = #slots`.

Per-variant AST from the declaration becomes one of:

```
{ name = "Some",   positional = true,  slots = { "a" },              arity = 1 }   -- Some(a)
{ name = "Circle", positional = false, fields = { "radius" } }                     -- Circle { radius }
{ name = "None"    (no positional, no fields) }                                     -- nullary
```

`Ctor()` (empty parens) is arity 0 — equivalent to nullary; prefer bare `Ctor`.

The checker's `build_registry` records, per constructor in `ctor_owner[name]`:

```
{ type = <type name>, positional = true,  arity = <n> }             -- positional
{ type = <type name>, positional = false, fields = {…}, fieldset }  -- named (existing)
```

## Construction

`parse_primary` handles an uppercase ident (a constructor). Today: optional `{ named }` else
nullary. Add: if the next token is `(`, parse a comma-separated list of **expressions** until
`)` → a positional `construct`:

```
{ kind = "construct", tag = "Some", positional = true, args = { <expr>, … }, line, col }
```

Named construction keeps `{ kind = "construct", tag, fields = {…} }` (no `positional`). The
`(args)` are consumed inside `parse_primary`, so they are not re-read as a function call.

**This removes today's obsolete rejection** in `gen_call` (codegen.lua:37-40) that errored on
`Ctor(...)` call syntax — that path only existed because positional construction was
unsupported; `Ctor(args)` is now parsed as a construct, never as a call, so a `construct` node
can no longer reach `gen_call`.

**Codegen** — a new branch beside the existing named `construct` case:

```lua
-- Some(3)      ⇒  { __tag = "Some", 3 }
-- Node(l, r)   ⇒  { __tag = "Node", l, r }
```
i.e. `"{ __tag = " .. quote_string(tag) .. ", " .. <arg exprs joined ", "> .. " }"` (omit the
trailing part for arity 0). Positional args occupy the Lua array part (`v[1]`, `v[2]`, …);
`__tag` stays in the hash part.

## Pattern

`parse_pattern` handles an uppercase ident as a constructor pattern: today optional
`{ field-pats }` else nullary. Add: if the next token is `(`, parse a comma-separated list of
**sub-patterns** until `)` → a positional `ctor_pat`:

```
{ kind = "ctor_pat", tag = "Some", positional = true, args = { <pattern>, … } }
```

Named `ctor_pat` keeps `fields = {…}` (no `positional`).

**Codegen** — the match `compile_pattern` `ctor_pat` case (codegen.lua:155) gains a positional
branch: test `type(access) == "table"` and `access.__tag == "<tag>"`, then recurse into each
sub-pattern at `access .. "[" .. i .. "]"`:

```lua
-- | Node(l, r) ->   tests: type==table, .__tag=="Node";  binds l=access[1], r=access[2]
```

Positional patterns must match the **full arity** (checker-enforced); use `_` to ignore a
slot (`Node(_, r)`).

## Typecheck

Alongside the existing named-field validations:

- **Construction arity** (`synth` `construct`, positional): `#args` must equal the declared
  `arity`; else `constructor 'Some' expects 1 argument, got 2` (pluralize "argument(s)").
  Synthesize each arg expression (recurse) as today.
- **Pattern arity** (`validate_pattern` `ctor_pat`, positional): `#args` must equal `arity`;
  else the same shape of error against the pattern's enclosing match node.
- **Shape mismatch** (both construct and pattern): a positional form used on a constructor the
  registry records as named — `constructor 'Circle' takes named fields, not positional
  arguments` — and the reverse for a named form on a positional constructor. This makes the
  two shapes mutually exclusive per constructor.
- **Undeclared constructors** stay lenient (the checker skips a tag with no registry owner),
  as today.
- **Exhaustiveness** (`check_exhaustive`) is unchanged — it keys on `__tag`; a positional
  `ctor_pat` contributes its `tag` exactly like a named one.

## Runtime rep & interactions

- `{ __tag = "Ctor", <args…> }` — dynamic; undeclared constructors still build at runtime.
- **Functional record update** (`{ v with … }`, a parallel cycle) and any `pairs` copy include
  both `__tag` and the array part, so they carry positional payloads through unchanged.
- `#value` on a positional variant equals its arity (array part length; `__tag` is in the hash
  part and does not count) — an incidental, harmless property.

## Testing strategy

New `spec/positional_ctor_spec.lua`, behavioral (`compiler.eval`) unless noted:

- construct + match a 1-arity ctor — `Some(3)` then `match … | Some(x) -> x` yields 3;
- 2-arity — `Node(l, r)` builds and matches, binding both slots;
- `_` ignores a slot — `| Node(_, r) -> r`;
- nullary still works alongside — `None` in the same type;
- positional and named constructors in one `type` both build/match;
- runtime rep — `Some(3).__tag == "Some"` and index 1 holds 3 (via a match bind);
- exhaustiveness over positional ctors — a match missing `None` errors; complete match passes;
- construction arity error — `Some(1, 2)` → diagnostic (assert message);
- pattern arity error — `Node(x)` on 2-arity → diagnostic;
- shape mismatch — `Some { x = 1 }` on positional `Some`, and `Circle(5)` on named `Circle`
  → diagnostics;
- emitted Lua `load()`s.

Plus one `docs/guide.md` ` ```egg ` example (CI-verified via the doctest harness), e.g. an
`Option`/`Some(x)` or a small `Tree`.

## File touchpoints

- **Modify:** `omelette/parser.lua` (`parse_type_decl` positional variant; `parse_primary`
  positional `construct`; `parse_pattern` positional `ctor_pat`).
- **Modify:** `omelette/codegen.lua` (positional `construct` emission; positional `ctor_pat`
  branch in `compile_pattern`; remove the obsolete `gen_call` constructor rejection).
- **Modify:** `omelette/typecheck.lua` (`build_registry` positional entries; positional arity
  + shape-mismatch validation in construct `synth` and `validate_pattern`).
- **Create:** `spec/positional_ctor_spec.lua`.
- **Modify:** `docs/guide.md` (one verified example).
- **Unchanged:** lexer, stdlib, searcher.

## Roadmap follow-ups (record in `docs/ROADMAP.md`)

- **Tuples** `(x, y)` + tuple patterns (the sibling spec) — then tuple patterns in
  destructuring `let`.
- Field types / generics for positional slots (`Some(number)`, parametric `a`).
- Constructors as first-class function values.
- Mark "Positional constructors" shipped in the roadmap's Shipped section on completion.
