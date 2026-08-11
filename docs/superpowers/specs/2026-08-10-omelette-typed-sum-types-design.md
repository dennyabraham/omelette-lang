# Omelette — Typed Sum Types (Structural Checking) Design

**Date:** 2026-08-10
**Status:** Approved design, pre-implementation
**Depends on:** sum types cycle 1 (runtime ADTs + `type` declarations), optional typing (the checker + opt-in wiring)

## Summary

Make the type checker **understand ADTs**: build a **variant registry** from `type`
declarations, then add three **structural** checks — **match exhaustiveness**,
**construction validation**, and **constructor-pattern validation** — all using only the
declarations' constructor and field *names* (no field type annotations, no inference). All
are **blocking errors** in the opt-in checker; the runtime paths never check, so a
non-exhaustive match still compiles-and-runs (raising at runtime only if it hits an
uncovered case).

**The spine:** a constructor is checked only if it is **declared**. Undeclared uppercase
constructors stay fully dynamic (`any`, no diagnostics) — preserving cycle-1's optional
declarations and matching optional typing's leniency. *Declare your type → get checking.*

## Goals

- `omelette check` / `build` / `run` flag: a non-exhaustive `match` on a declared variant, a
  construction with wrong/missing/extra fields, and a constructor pattern with an unknown field.
- Zero new syntax (declarations already carry constructor + field names).
- No change to runtime behavior; the checker stays opt-in and off the runtime path.
- No false positives on existing code (undeclared constructors and non-variant matches are lenient).

## Non-Goals (deferred)

- **Field / argument type checking** (`radius` is a `number`) — needs field type annotations
  in declarations (`{ radius: number }`) + optional-typing collection work. _Next cycle._
- **Generics / parametric variants**, **type aliases**.
- **Rust-strict guard handling** — a guarded constructor arm counts as *covered* here (see below).
- **Redundant/unreachable arm warnings** (e.g. a dead literal arm after a catch-all).
- A **warning** severity — everything is a blocking error (consistent with the error-only checker).

## Decisions

| Decision | Choice |
|---|---|
| Scope | **Structural**: registry + exhaustiveness + construction/pattern validation (names only) |
| Severity | **Blocking error** (Rust-style; consistent with the existing error-only checker) |
| Undeclared constructors | **Lenient** — dynamic `any`, no diagnostics (declaration stays optional) |
| Guarded constructor arm | **Counts as covered** (runtime no-match `error` backstops a guard fall-through) |
| Where checking runs | Opt-in only (`check`/`build`/`run`); runtime `eval`/searcher/REPL never check |

## The Variant Registry

Built once at the start of `typecheck.check`, scanning **all** top-level `type_decl` nodes
(program-global, order-independent):
- `types[T] = { ctors = { <CtorName>… }, fields = { <CtorName> = { <fieldName>… } } }`
- `ctor_owner[<tag>] = { type = <T>, fields = { <fieldName>… } }` (reverse map)

A constructor name declared in two different types → diagnostic ("constructor `Circle`
declared in both `Shape` and `Foo`"), since it breaks the tag→type uniqueness exhaustiveness
relies on.

## Check 1 — Construction validation (`construct`)

When synthesizing a `construct` node, if `node.tag` is **declared** (in `ctor_owner`):
- the provided field keys must **exactly** match the declared field set → diagnostic on any
  **missing**, **extra**, or **misspelled** field (`Circle { radiuz = 5 }` → "unknown field
  'radiuz' for constructor 'Circle' (fields: radius)"; `Circle {}` → "missing field 'radius'").
- field values are still synthesized (to catch errors inside them) and the result type is `any`.
If `node.tag` is **undeclared** → no validation (lenient), result `any`.

## Check 2 — Constructor-pattern validation (`ctor_pat`)

A `validate_pattern(pat)` recursion visits every `ctor_pat` in a match arm's pattern (top-level
**and** nested). For a **declared** tag, the pattern's field keys must be a **subset** of the
declared fields (partial destructuring is allowed; an **unknown** field → diagnostic). Undeclared
tag → lenient.

## Check 3 — Match exhaustiveness (`match`)

For each `match`, examine only the arms' **top-level** patterns (nested patterns are
destructuring, not the discriminant):
1. Collect the constructor tags appearing as a top-level `ctor_pat` across the arms.
2. **No tags** → not a variant match (literals/vars/wildcards) → **skip** (the runtime no-match
   `error` remains the backstop for literal matches).
3. **Unguarded catch-all** present (a top-level `var` or `wildcard` arm with **no** `when` guard)
   → **exhaustive**, done.
4. Otherwise map tags to owning types:
   - any **undeclared** tag → can't check → **skip** (lenient).
   - tags span **multiple** declared types → diagnostic ("match mixes constructors of `Shape`
     and `Option`").
   - all tags belong to one declared type `T` → every constructor of `T` must appear among the
     arm tags → **missing → diagnostic** ("non-exhaustive match: missing `Rect`, `Origin`").

A **guarded** constructor arm (`| Circle { r } when r > 0 ->`) counts as covering its
constructor (documented simplification; the runtime `error("match: no matching case")` backstops
the guard-fall-through edge).

## Wiring (unchanged; reuses optional typing's opt-in model)

- All new diagnostics are `errors.new` values collected by the checker → returned by
  `compiler.check`, and made **blocking** by `compiler.compile(src, { check = true })` (the first
  diagnostic aborts) and the CLI `check` / `build` / `run` (unless `--no-check`).
- **`compiler.compile(src)` (no opts), `compiler.eval`, the searcher, and the REPL never check** —
  a non-exhaustive match still compiles-and-runs. A type error can never become a load-time crash.
- `resolver.resolve` stays the identity pass on the hot path.

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), existing harness.

- **Registry / construction:** missing / extra / misspelled field on a declared constructor →
  diagnostic; correct fields → clean; **undeclared constructor → lenient** (no diagnostic);
  duplicate constructor across two types → diagnostic.
- **Pattern validation:** unknown field in a `ctor_pat` (top-level and nested) → diagnostic;
  partial/subset destructuring → clean.
- **Exhaustiveness:** all constructors covered → clean; a missing constructor → diagnostic naming
  the missing ones; an unguarded wildcard/var catch-all → clean despite gaps; a guarded
  constructor arm → clean (counts as covered); mixed-type match → diagnostic; a non-variant
  (literal-only) match → **no** exhaustiveness diagnostic; undeclared constructors → lenient.
- **Wiring / behavioral:** `compiler.check(src)` surfaces a non-exhaustive-match diagnostic;
  `compiler.compile(src, {check=true})` returns nil + that diagnostic; **`compiler.compile(src)`
  and `compiler.eval(src)` still compile and run the same (non-exhaustive) program**; the stdlib
  still checks clean (it uses no `type` declarations).
- **No regression:** existing sum-type behavioral/typecheck tests stay green — Option/Shape/Tree
  matches are already exhaustive; the nested-pattern test has a wildcard catch-all. Adjust an
  existing test only if it is genuinely non-exhaustive (a latent bug the check correctly surfaces).

## File Touchpoints

- `omelette/typecheck.lua` — build the registry in `check`; validate `construct` fields; a
  `validate_pattern` recursion for `ctor_pat` fields; the exhaustiveness algorithm in the `match`
  synth; a helper to detect an unguarded catch-all and to map tags→types.
- `spec/` — registry/construction, pattern-validation, exhaustiveness, and wiring tests.

No changes to lexer, parser, codegen, compiler, resolver, CLI, REPL, or searcher (the diagnostics
flow through the existing opt-in wiring).

## Deferred (record in `docs/DEFERRED.md`)

- **Field/argument type checking** (`{ radius: number }`), generics, type aliases.
- **Rust-strict guards** (guarded-only constructor is non-exhaustive), **redundant-arm warnings**,
  and a **warning** severity in the diagnostic model.
