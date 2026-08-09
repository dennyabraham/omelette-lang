# Omelette — Deferred Work & Backlog

A consolidated, durable record of things intentionally **not** built yet, with the
rationale and where the decision was made. Individual specs' Non-Goals sections remain
the authoritative detail; this file is the index so nothing gets lost between cycles.

_Last updated: 2026-07-16 (after dict comprehensions + merge; stdlib complete)._

## Language features

- **~~Map-producing dict comprehensions~~** (`{ k => v | … }`) — ✅ **DONE** (2026-07-16):
  build a dict with dynamic keys; new `=>` token, shared qualifier machinery, IIFE codegen.
  Unblocked **`std.table.merge`** (also done).
- **Descending ranges / custom step** — `[5 to 1]` is *empty*, not descending; no
  `[a, b .. c]` step form. _Source: range-dict-comprehensions spec._
- **~~`if` / `match` as sub-expressions~~** — ✅ **DONE**: `match` (2026-08-02) and `if`
  (2026-08-07) are both first-class expressions now (IIFE codegen in `codegen.expr`). A
  parenthesized `(if …)`/`(match …)`/`(fn …)` works in any expression position (ML-style). `if`
  keeps its non-closure statement-lowering in the common binding/branch/return positions
  (`gen_if` only fires for a genuine sub-expression). _Source: pattern-matching + if-expression cycles._
- **~~Top-level forward references / mutual recursion~~** — ✅ **DONE** (2026-07-13):
  `M.program` now forward-declares all top-level locals (`local a, b, …`) then assigns, so
  top-level functions reference each other in any order (mutual recursion / forward refs).
  (Value bindings that eagerly read a not-yet-computed sibling remain a runtime error —
  inherent.)
- **~~Richer pattern matching~~** — ✅ **DONE** (2026-08-02): variable-binding, array/record
  destructuring (pun + rename, nested), and guards (`when`); `match` compiles to an IIFE (now a
  first-class expression); no-match raises a runtime error. Remaining pattern work (deferred):
  **or-patterns** (`| 0 | 1 ->`), **as-patterns** (`x as [a,b]`), **negative-number literal
  patterns** (`| -1 ->` doesn't parse), **record key-presence testing** (fields bind nil if
  absent, by design), **non-linear/hygiene** (`[a, a]` last-wins), and the **greedy nested-form
  arm** (parenthesize an inner `match`/`if` in an arm body to delimit it). ADT/constructor
  patterns + compile-time exhaustiveness need sum types (below). _Source: 2026-08-02 spec + reviews._
- **~~Sum / variant types (cycle 1: runtime ADTs)~~** — ✅ **DONE** (2026-08-08): `type` declarations
  with capitalized named-field constructors (`Circle { radius = 5 }` → `{ __tag = "Circle", radius = 5 }`),
  constructor patterns in `match`, tagged-record runtime rep. Dynamic; the `type` declaration is
  erased. _Source: 2026-08-08 sum-types spec._
- **Sum types — typed cycle & extensions (deferred):**
  - **Field/arg type-checking + compile-time match exhaustiveness** — the checker reads `type`
    declarations to type constructor fields and check coverage (tags are globally unique, so a
    match's constructor patterns identify the type). The runtime no-match `error` becomes the
    fallback the checker still permits. _The headline typed payoff._
  - **Generics / parametric variants** (`type Option(a) = Some { value: a } | None`), **field
    type annotations** in declarations, **positional-field constructors**, and **constructors as
    first-class function values** (construction is currently inlined).
  - `type aliases`. _Source: v1 spec + sum-types design._
- **Custom operators, macros.** _Source: v1 spec._
- **~~`pub let` recursion-by-name~~** — ✅ **DONE** (stdlib cycle): top-level bindings now emit
  as `local` + `M.name = name`, so `pub` functions recurse and cross-reference by name.
- **Index assignment `xs[i] = v`** — intentionally omitted; indexing is read-only to keep
  the surface immutable. _Source: indexing-length spec._
- **String character indexing `s[i]`** — Lua returns `nil`; use `string.sub`. `#s` (length)
  is supported. _Source: indexing-length spec._

## Type system

- **~~Optional typing (cycle 1)~~** — ✅ **DONE** (2026-07-21): erased, compile-time-only optional
  types — `:` annotations, `omelette/typecheck.lua` (primitives + function types + `any`), opt-in
  `omelette check` + `build`/`run --no-check`. Runtime paths (searcher/embed/REPL) never check;
  generated Lua byte-identical. _Source: 2026-07-20 optional-typing spec._
- **Optional typing — cycle 2 & refinements:**
  - **Collection types** `[T]` / `{ x: T }` and typing the stdlib; **richer inference**
    (unification / HM). _Deferred from cycle 1._
  - **Bidirectional branch checking** — `if`/`match` with divergent branches currently join to
    `any`, so a knowable mismatch against a declared return type (`let f (b: boolean): number =
    if b then 1 else "x"`) is under-reported. Check branches against the expected type instead of
    only synthesizing. _Source: cycle-1 reviews._
  - **Walk comprehension/range/dict-comp bodies** — currently synthesize to `any` without
    recursing, so operator mismatches inside a yield are missed (never a false positive).
  - **Better function-type diagnostics** — `tyname` collapses all `fun` types to `"function"`;
    render the signature. _Source: cycle-1 reviews._
- **`--runtime-checks`** — opt-in codegen mode emitting boundary guards (`assert(type(x)==…)`)
  from annotations (the "true gradual" soundness down-payment; default output stays erased). _Backlogged from the typing-model decision._
- **Lambda parameter annotations** — lambdas are untyped (`any` params) in cycle 1. _Deferred._

## Tooling & infrastructure

- **~~CI & release automation~~** — ✅ **DONE** (merged; CI green under LuaJIT + Lua 5.4).
  Remaining opt-ins when ready: **LuaRocks publish** activates once the repo is public and a
  `LUAROCKS_API_KEY` secret is set (the release workflow's step is already gated on both);
  the first tagged release requires a matching `## [X.Y.Z]` CHANGELOG entry.
- **Performance / benchmark harness** — compare codegen quality vs hand-written Lua. _Source: v1 spec._
- **`omelette test`** (thin busted wrapper), **formatter** (`eggfmt`), **LSP**. _Source: v1 spec._
- **Full source maps** — beyond the light `--[[omelette:LINE]]` comments. _Source: v1 spec._

## Quality / cleanup follow-ups (none blocking)

- **Literal-base field access / call wrapping** — indexing a literal base is parenthesized
  (`({..})[k]`), but **field access** (`{a=1}.a`, `Circle { r = 5 }.r`) and **calling** a literal
  emit unparenthesized, unloadable Lua 5.1 (`{..}.a` → syntax error). Pre-existing, but sum types
  make `Ctor { .. }.field` idiomatic. Fix: generalize the index wrap-guard to the `field` and
  `gen_call` paths. (Loud load-time error, never silent.) _Source: sum-types whole-branch review._
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

## Standard library

- ✅ **Complete.** `std.list` / `std.string` / `std.table` (incl. **`merge`**, added 2026-07-16
  via dict comprehensions). Nothing outstanding.
