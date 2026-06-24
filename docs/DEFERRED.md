# Omelette — Deferred Work & Backlog

A consolidated, durable record of things intentionally **not** built yet, with the
rationale and where the decision was made. Individual specs' Non-Goals sections remain
the authoritative detail; this file is the index so nothing gets lost between cycles.

_Last updated: 2026-06-24 (after the standard library)._

## Language features

- **Map-producing dict comprehensions** (`{ k => v | … }`) — and therefore the stdlib's
  **`merge`**. Building a *new* dict with dynamic keys has no path today.
  _Source: range-dict-comprehensions spec (Non-Goals)._
- **Descending ranges / custom step** — `[5 to 1]` is *empty*, not descending; no
  `[a, b .. c]` step form. _Source: range-dict-comprehensions spec._
- **`if` / `match` as sub-expressions** — they only work in binding/return/branch position;
  a bare `if`/`match` can't be a value sub-expression. Since the stdlib cycle made call
  arguments parse via `parse_expr_or_form`, `f(if c then a else b)` now *parses* but fails
  at codegen (`cannot emit expression of kind 'if'`) — a parse→codegen failure-quality
  regression. Fix by applying the comprehension/range IIFE lowering to `if`/`match` (so they
  work everywhere), or reject them at parse time in arg position. _Source: comprehensions +
  stdlib whole-branch reviews._
- **Top-level forward references / mutual recursion** — since the stdlib codegen change emits
  top-level bindings as `local function`/`local x` in source order (no hoisting), a function
  that calls a *later*-defined sibling compiles but fails at runtime (nil global). Definitions
  must currently precede uses; mutually-recursive top-level functions are impossible. Fix by
  forward-declaring all top-level locals (`local a, b, …` then assign). _Source: stdlib
  whole-branch review._
- **Sum / variant types, exhaustiveness checking, type aliases.** _Source: v1 spec._
- **Custom operators, macros.** _Source: v1 spec._
- **~~`pub let` recursion-by-name~~** — ✅ **DONE** (stdlib cycle): top-level bindings now emit
  as `local` + `M.name = name`, so `pub` functions recurse and cross-reference by name.
- **Index assignment `xs[i] = v`** — intentionally omitted; indexing is read-only to keep
  the surface immutable. _Source: indexing-length spec._
- **String character indexing `s[i]`** — Lua returns `nil`; use `string.sub`. `#s` (length)
  is supported. _Source: indexing-length spec._

## Type system

- **Gradual / optional type checking** — annotation *parsing* (`let f (x: number) … `) plus
  a checker, landing in the reserved `resolver` seam. This is the big future feature.
  _Source: v1 spec (Future Scope)._

## Tooling & infrastructure

- **CI & release automation** — fully specced (`docs/superpowers/specs/2026-06-21-omelette-ci-release-design.md`),
  build cycle not yet executed. LuaRocks publish is gated on the repo being public + a
  `LUAROCKS_API_KEY` secret. _Status: specced, parked._
- **Performance / benchmark harness** — compare codegen quality vs hand-written Lua. _Source: v1 spec._
- **`omelette test`** (thin busted wrapper), **formatter** (`eggfmt`), **LSP**. _Source: v1 spec._
- **Full source maps** — beyond the light `--[[omelette:LINE]]` comments. _Source: v1 spec._

## Quality / cleanup follow-ups (none blocking)

- **Nested-IIFE indentation** — a comprehension/range nested in an indented position emits
  under-indented (but correct, runnable) Lua, because `M.expr` has no `pad` parameter.
  Cosmetic. _Source: comprehensions + range whole-branch reviews._
- **Wildcard-only `match`** — `match n with | _ -> x` (no literal arms) emits a bare `else`,
  which is invalid Lua. Pathological input (a wildcard-only match is pointless). _Source: v1 review._
- **CLI `--out` write error** reports source position `1:1` (cosmetic). _Source: v1 / indexing reviews._
- **Parser `at`/`peek` overshoot guard** — safe today via the lexer's EOF token; a nil-guard
  would harden it. _Source: v1 review._
- **`searcher.install()` idempotency** — re-registers the loader and accumulates roots on each
  call. _Source: v1 review._

## Standard library (in progress)

- **`merge`** is deferred within the stdlib until map-producing dict comprehensions exist
  (see Language features, above). `get`/`has` work today via `xs[i]`.
