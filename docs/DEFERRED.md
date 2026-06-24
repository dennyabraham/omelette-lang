# Omelette — Deferred Work & Backlog

A consolidated, durable record of things intentionally **not** built yet, with the
rationale and where the decision was made. Individual specs' Non-Goals sections remain
the authoritative detail; this file is the index so nothing gets lost between cycles.

_Last updated: 2026-06-23 (after range literals + key/value generators)._

## Language features

- **Map-producing dict comprehensions** (`{ k => v | … }`) — and therefore the stdlib's
  **`merge`**. Building a *new* dict with dynamic keys has no path today.
  _Source: range-dict-comprehensions spec (Non-Goals)._
- **Descending ranges / custom step** — `[5 to 1]` is *empty*, not descending; no
  `[a, b .. c]` step form. _Source: range-dict-comprehensions spec._
- **`if` / `match` as sub-expressions** — currently they only work in binding/return/branch
  position (a bare `if` can't be a call argument). The IIFE technique used for
  comprehensions/ranges could be applied to them. _Source: comprehensions whole-branch review._
- **Sum / variant types, exhaustiveness checking, type aliases.** _Source: v1 spec._
- **Custom operators, macros.** _Source: v1 spec._
- **`pub let` recursion-by-name** — a `pub let f` can't call itself by bare name (it's
  `function M.f`); the local-impl + `pub` alias pattern is the current workaround.
  _Source: indexing-length spec._
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
