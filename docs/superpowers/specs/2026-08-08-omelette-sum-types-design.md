# Omelette — Sum Types (Cycle 1: Runtime ADTs) Design

**Date:** 2026-08-08
**Status:** Approved design, pre-implementation
**Depends on:** richer pattern matching (the match IIFE + `compile_pattern`), optional typing (checker touch)

## Summary

Add **runtime algebraic data types**: `type` declarations with named-field, capitalized
constructors, tagged-record construction (`Circle { radius = 5 }`), and constructor patterns
in `match` (`| Circle { radius } -> …`). This is **cycle 1 — the runtime feature**: it is
**dynamically typed** (construction and matching are driven by *capitalization + syntax + a
runtime `__tag`*), so it delivers real ADTs (Option/Result/trees) immediately.

The type-system payoff — **checking constructor fields and match exhaustiveness** — is the
**next cycle** (it needs the checker to read these declarations). In cycle 1 the `type`
declaration is parsed-and-**erased** (compile-time documentation + the forward-compatible
anchor the typed cycle builds on), exactly like optional-type annotations.

## Goals

- Declare variant types: `type Shape = | Circle { radius } | Rect { width, height } | Origin`.
- Construct: `Circle { radius = 5 }`, `Origin`.
- Match/deconstruct: `| Circle { radius } -> radius`, `| Origin -> 0`.
- Runtime-only: works without the type checker; generated Lua is plain tagged tables.

## Non-Goals (deferred to the typed cycle / later)

- **Type-checking constructor fields** and **compile-time match exhaustiveness** — the headline
  type-system payoff; needs the checker to read `type` declarations. _Next cycle._
- **Generics / parametric variants** (`type Option(a) = Some { value: a } | None`) — later.
- **Positional-field constructors** (we chose named fields) and passing a **constructor as a
  first-class function value** (construction is inlined) — later if wanted.
- **Field type annotations** in declarations (`{ radius: number }`) — the typed cycle adds them.

## Decisions

| Decision | Choice |
|---|---|
| Scope | **Runtime ADTs** — dynamic; typing/exhaustiveness deferred |
| Constructor vs variable | **Capitalization**: constructors are uppercase-initial; lowercase idents are variables |
| Payload style | **Named fields** (record-like): `Circle { radius }` |
| Construction syntax | **`Ctor { field = v }`** (juxtaposition; inlined to a tagged table) |
| Runtime representation | **`{ __tag = "Ctor", field = v, … }`** (`__tag` namespaced so a user `tag` field can't clash) |
| `type` declaration at runtime | **Erased** (compile-time only; anchor for the typed cycle) |

## Surface

```
type Shape =
  | Circle { radius }
  | Rect { width, height }
  | Origin

pub type Option =            -- `pub type` exports the constructors' usability across modules
  | Some { value }
  | None

let area s =
  match s with
  | Circle { radius }        -> 3 * radius * radius
  | Rect { width, height }   -> width * height
  | Origin                   -> 0

let unwrap_or opt fallback =
  match opt with
  | Some { value } -> value
  | None           -> fallback
```

Semantics:
- A **constructor** is an uppercase-initial name. `Ctor { f = v, … }` builds a value; a bare
  `Ctor` (no braces) builds a nullary value.
- Fields are **named**; construction and matching both name them (pun `{ radius }` or, in
  patterns, rename/nest `{ radius: p }`).
- **Capitalization is the rule**: uppercase → constructor (in both expression and pattern
  position); lowercase → variable. Existing Omelette/stdlib code uses no uppercase idents, so
  this is non-breaking.
- In cycle 1 the `type` declaration is **not load-bearing at runtime** — construction and
  matching work from capitalization + `__tag`. Declaring is recommended (documentation +
  required by the future typed cycle) but a program can construct/match constructors that were
  declared; codegen erases the declaration.

## Lexer

Add `type` to `KEYWORDS`.

## Parser

**`type` declaration** — a new top-level statement (`parse_statement` dispatches on `type`,
including `pub type`; top-level only, like other statements):
- Grammar: `(pub)? type Name = (|)? Variant (| Variant)*`.
- `Variant` = an **uppercase** constructor name + optional `{ field, … }` (bare `ident` fields).
  A lowercase constructor name → `self:fail("constructor names must be capitalized")`.
- AST: `{ kind = "type_decl", name = <string>, is_pub = <bool>, variants = { { name = <string>, fields = { <string>… } }… }, line, col }`.

**Construction** — in `parse_primary`, when the current `ident` token is **uppercase-initial**:
- consume it; if the next token is `{`, parse record-literal fields (`ident = expr`,
  comma-separated) → `{ kind = "construct", tag = <name>, fields = { { key, value }… }, line, col }`.
- otherwise → `{ kind = "construct", tag = <name>, fields = {}, line, col }` (nullary).
- lowercase ident → `{ kind = "ident" }` (unchanged).

**Constructor patterns** — in `parse_pattern`, when the ident is **uppercase-initial**:
- consume it; if next is `{`, parse record-pattern fields (pun `{ x }` → `pat = var x`; rename
  `{ x: p }`) → `{ kind = "ctor_pat", tag = <name>, fields = { { key, pat }… } }`.
- otherwise → `{ kind = "ctor_pat", tag = <name>, fields = {} }` (nullary).
- lowercase ident → `{ kind = "var" }` (unchanged).

Uppercase-initial test: `name:sub(1, 1):match("%u") ~= nil`.

## Codegen

- **`type_decl`** — emits nothing. In `M.program`'s top-level loop, a `type_decl` node is
  skipped (not emitted, not forward-declared — constructors are not bindings).
- **`construct`** (in `expr`) → `"{ __tag = " .. quote(tag) .. <", key = value"…> .. " }"`,
  e.g. `{ __tag = "Circle", radius = (5) }`; nullary → `{ __tag = "Origin" }`. Reuses the
  record field-emission style (`f.key .. " = " .. expr(f.value, ctx)`).
- **`ctor_pat`** (in `compile_pattern`, inside the match IIFE) → append tests
  `type(access) == "table"` and `access.__tag == "<tag>"`, then recurse each field pattern
  against `access .. "." .. field.key` (exactly like `record_pat`, plus the tag test).

## Typecheck (minimal; dynamic in cycle 1)

- **`M.check`** skips `type_decl` (not an expression; no binding).
- **`construct`** synth → walk each `field.value` (to surface errors inside them), return `ANY`.
- **`collect_pattern_vars`** handles `ctor_pat` (recurse `fields[].pat`, like `record_pat`), so
  constructor-pattern-bound variables are `any` in the arm.
- No new diagnostics from sum types themselves (dynamic); no false positives.

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), existing harness.

- **Lexer:** `type` is a keyword.
- **Parser:** `type_decl` AST (variants + fields, `pub`, leading-`|`, lowercase-ctor error);
  `construct` node (with fields + nullary); `ctor_pat` (with fields + nullary + nested).
- **Codegen golden:** `construct` → `{ __tag = "Circle", radius = (5) }`; `ctor_pat` → the
  `type()`/`.__tag ==` tests; `type_decl` emits nothing.
- **Behavioral (compile + run) — the proof:**
  - Option: `Some { value = 5 }` / `None`; `match … | Some { value } -> value | None -> 0`.
  - `area` over a `Shape` (Circle/Rect/Origin) dispatching on the constructor.
  - a recursive type (e.g. `Node { left, value, right }` / `Leaf`) summed via a recursive
    function + match.
  - nested constructor pattern (`Some { value: [a, b] } -> a + b`) and a guard on a ctor arm.
  - `__tag` doesn't clash with a user field named `tag` (`Circle { tag = 9, radius = 1 }` works).
  - `pub type` — constructors usable from the compiled module.
- **Typecheck:** a program with type decls + construction + constructor patterns → no false
  positives; a real mismatch elsewhere still caught; the stdlib still checks clean.

## File Touchpoints

- `omelette/lexer.lua` — add `type` keyword.
- `omelette/parser.lua` — `parse_type_decl` (dispatched from `parse_statement`); uppercase-ident
  construction in `parse_primary`; constructor patterns in `parse_pattern`.
- `omelette/codegen.lua` — `construct` in `expr`; `ctor_pat` in `compile_pattern`; skip
  `type_decl` in `M.program`.
- `omelette/typecheck.lua` — skip `type_decl` in `check`; synth `construct`; handle `ctor_pat`
  in `collect_pattern_vars`.
- `spec/` — lexer, parser, codegen-golden, behavioral, and typecheck tests.

No changes to compiler, resolver, CLI, REPL, or searcher.

## Deferred (record in `docs/DEFERRED.md`)

- **Typed sum types (next cycle):** the checker reads `type` declarations to type constructor
  fields, type `construct`/`ctor_pat`, and — the headline — **compile-time match exhaustiveness**
  (constructor tags are globally unique, so a match's patterns identify the type and coverage can
  be checked; the runtime no-match `error` becomes the fallback the checker still permits).
- **Generics / parametric variants** (`Option(a)`), **field type annotations**, **positional-field
  constructors**, and **constructors as first-class function values**.
