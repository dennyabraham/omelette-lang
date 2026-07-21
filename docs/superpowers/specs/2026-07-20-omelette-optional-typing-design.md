# Omelette — Optional Typing (Cycle 1) Design

**Date:** 2026-07-20
**Status:** Approved design, pre-implementation
**Depends on:** the full v1+ compiler (this is the first cut of the long-planned type system)

## Summary

Add **optional, erased static typing** to Omelette — annotations you *may* write, checked at
compile time and then **erased** (generated Lua is byte-identical). This is **cycle 1: a thin
vertical slice** — annotation parsing plus a minimal checker covering **primitives + function
types + `any`**, checking value-binding, function-return, call-argument, and operator
consistency. Arrays/records types and richer inference are cycle 2; runtime contracts are
backlogged.

Crucially, type checking is **dev/build-time only and opt-in**: the runtime paths (the
`require` searcher, the embeddable `compile`/`eval`, the REPL, the single-file artifact used as
a library) **never type-check** — they erase-and-run, so a type error can never turn into a
production load-time crash.

## Goals

- Write `let add (x: number) (y: number): number = x + y`; a mismatch is caught at dev time.
- Generated Lua is **byte-identical** with or without annotations (full erasure).
- Runtime/embedded compilation never checks (fast, never blocked by a type error).
- The checker is a self-contained, independently-testable module.

## Non-Goals (cycle 1 — deferred)

- **Array/record/collection types** (`[T]`, `{ x: number }`) and typing the stdlib — **cycle 2**.
- **Richer inference** (unification / Hindley-Milner) — cycle 1 does only bottom-up synthesis.
- **Runtime contracts** (`--runtime-checks` emitting `assert(type(x)==…)` guards) — backlogged
  (the "true gradual" soundness down-payment).
- **Lambda parameter annotations** — lambdas stay untyped (`any` params) in cycle 1.
- **Soundness / completeness** — this is optional typing; untyped and Lua-interop code is `any`
  and never errors.

## Decisions

| Decision | Choice |
|---|---|
| Typing model | **Optional / erased** — compile-time only, no runtime effect, Lua output unchanged |
| First cut | **Thin vertical slice**: annotation parsing + minimal checker (primitives + functions + `any`) |
| Annotation token | **`:`** (kept free; add to lexer) |
| Function type | **`(T1, T2) -> R`** (parenthesized param list; matches multi-arg, non-curried calls) |
| Dynamic type | **`any`** (keyword) |
| Where checking runs | **opt-in, dev/build-time only**; runtime `compile()`/searcher/embed/REPL never check |
| CLI behavior | **`omelette check <file>`** reports all; **`build`/`run`** check-and-block, `--no-check` to skip |
| Checker home | new **`omelette/typecheck.lua`**; the `resolver` seam stays a light identity pass on the hot path |

## Type Language & Annotation Syntax

Annotations use `:` and appear in three places:
```
let add (x: number) (y: number): number = x + y   -- typed params + return
let greet (name: string) = "hi, " .. name          -- typed param, inferred return
let count: number = 0                              -- typed value binding
let f x y = x + y                                  -- untyped: params are `any`
```
- **Params:** parenthesized `(name: type)`; bare `name` params are `any`; mixing is allowed.
- **Return:** `: type` after the param list, before `=`.
- **Value bindings:** `let name: type = expr`.

**Type grammar** (`parse_type()`, only in annotation position — so `->`/`{}` there are types,
no clash with expression syntax). **Cycle 1 implements the bold subset:**
- **`number`, `string`, `boolean`, `nil`** — primitives.
- **`any`** — the dynamic type; consistent with everything.
- **Function types `(T1, …) -> R`** — e.g. `(number, number) -> number`, `() -> nil`.
- `[T]` array type, `{ x: number, … }` record type — **cycle 2**.

**Erasure:** annotations parse into new AST fields that **codegen ignores entirely**.

## The Checker (`omelette/typecheck.lua`)

`check(program) -> diagnostics` — a list of value-based `{message, line, col}` (empty if clean).

**Type representation** (plain tagged tables): `{kind="number"|"string"|"boolean"|"nil"|"any"}`
and `{kind="fun", params={<type>…}, ret=<type>}`.

**Consistency** `consistent(a, b)`:
- `any` on either side → consistent.
- both primitive → `a.kind == b.kind`.
- both `fun` → same arity and each param + the return pairwise consistent.
- otherwise → inconsistent.

**Bottom-up synthesis** `synth(node, env) -> type`:
- literals → their primitive type; `ident` → env lookup else `any` (Lua globals `string`/`table`/`print` → `any`).
- **binop:** arithmetic `+ - * / %` → operands must be consistent with `number`, result `number`;
  `..` → operands consistent with `string`, result `string`; comparisons `== ~= < <= > >=` →
  result `boolean` (no operand constraint in cycle 1); `and`/`or` → `any`.
- **unop:** `-` → operand `number`, result `number`; `not` → `boolean`; `#` → `number`.
- **call:** synth the callee; if it is a `fun` type, check arity and each argument consistent
  with the corresponding param, result = `ret`; if the callee is `any` → result `any`, no checks.
  (Calls containing `_` holes — partial application — are not arity/arg-checked in cycle 1.)
- **index / field / array / table / comprehension / range / dict-comprehension / lua_raw** →
  `any` (collection typing is cycle 2).
- **lambda** → `{kind="fun", params={any…}, ret = synth(body)}`.
- **if / match / block** → for return-type synthesis: `if`/`match` → the common branch type if all
  branches agree, else `any`; `block` → the type of its result expression.

**Checks (collect diagnostics):**
- value binding `let x: T = e` → error if `synth(e)` not consistent with `T`.
- function `let f (…): R = body` → build a scope with each param's declared type (or `any`);
  if `R` is annotated and `synth(body)` is not consistent with `R` → error.
- call arguments and operator operands as above.

**Two passes over the module:**
1. Record every top-level `let`'s declared type into the global env — function → `fun` with its
   (annotated-or-`any`) params and (annotated-or-`any`) return; value → its annotation or the
   synth of its initializer. (So calls to later-defined / mutually-recursive functions resolve.)
2. Check each binding's body/initializer, calls, and operators; collect all diagnostics.

The env is scoped (function params, block `let`s shadow the global env); unknown names → `any`.

## Wiring

- **`resolver.resolve` stays a light identity pass** — it is on the runtime `compile()` hot
  path (searcher/embed/REPL); the checker must not live there.
- **`compiler.check(source) -> diagnostics, err`** — parse, then `typecheck.check`; returns
  **all** type diagnostics (or a parse `err`).
- **`compiler.compile(source, opts)`** — gains `opts.check`. When `opts.check` is set and
  `typecheck.check` finds any diagnostics, return `nil, <first diagnostic>` (blocking). Default
  (no `opts`) is unchanged: no checking → erase-and-run. `compiler.eval` and the searcher call
  `compile` **without** `check`.
- **CLI:** `omelette check <file>` → `compiler.check`, render all diagnostics, non-zero exit on
  any. `omelette build`/`run` → pass `{check = true}` unless `--no-check` is given.

## Erasure / Codegen

No codegen change. The new `let` AST fields (`param_types`, `ret_type`, `value_type`) and the
`parse_type` nodes are read only by `typecheck`. A behavioral test asserts the emitted Lua for a
fully-annotated program is byte-identical to its unannotated twin.

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), existing harness.

- **Lexer:** `:` tokenizes; `any` is a keyword.
- **Parser:** typed params `(x: number)`, return `: R`, value `let x: T`; `parse_type` for each
  primitive, `any`, and function types `(number, string) -> number`; untyped params still parse.
  **Erasure:** `codegen.program` output for an annotated program equals the unannotated version.
- **`typecheck` unit tests:** `consistent` truth table (`any` universal; primitives; functions).
  Good programs → `{}` (no diagnostics). Bad programs → the expected diagnostic:
  `let x: number = "hi"`; `let f (x: number): number = x .. "!"` (returns string); a call
  `let bad = add(1, "x")` where `add` is `(number, number) -> number`; arithmetic on a string.
  `any`/unannotated/Lua-interop (`vim.api.foo(1, "x")`, calling an unannotated `f`) → no error.
- **Wiring/behavioral:** `compiler.compile(src, {check=true})` returns nil + a diagnostic for a
  bad program, while `compiler.compile(src)` (no opts) **succeeds and the program runs** (erase-
  and-run); `compiler.check(src)` returns all diagnostics; a clean annotated program checks and
  runs. CLI: `omelette check` on a bad fixture exits non-zero; `omelette build --no-check` skips.

## File Touchpoints

- `omelette/lexer.lua` — add `:` op and `any` keyword.
- `omelette/parser.lua` — `parse_type()`; typed params / return / value-binding annotations;
  new `let` AST fields (`param_types`, `ret_type`, `value_type`).
- `omelette/typecheck.lua` — **new** module: type rep, `consistent`, `synth`, `check`.
- `omelette/compiler.lua` — `check(source)`; `compile(source, opts)` with `opts.check`.
- `omelette/cli.lua` — `check` subcommand; `--no-check` on `build`/`run`.
- `spec/` — lexer, parser (+ erasure), typecheck unit, and wiring/behavioral tests.

No changes to codegen, the searcher, or `resolver` (stays identity).

## Deferred (recorded in `docs/DEFERRED.md`)

- **Cycle 2:** array/record/collection types, typing the stdlib, richer inference.
- **`--runtime-checks`:** opt-in codegen mode emitting boundary guards from annotations (the
  gradual-typing soundness down-payment).
- **Lambda parameter annotations.**
