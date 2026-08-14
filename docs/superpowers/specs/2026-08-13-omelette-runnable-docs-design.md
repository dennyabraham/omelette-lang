# Omelette — Runnable Documentation Design

**Date:** 2026-08-13
**Status:** Approved design, pre-implementation
**Depends on:** the full compiler (`omelette.compiler` — `eval`/`compile`/`check`); the in-repo test harness (`spec/run.lua`)

## Summary

A concise, example-driven **`docs/guide.md`** whose every code example is **compiled and run as
part of the test suite** (and therefore CI), so the documentation can never drift from the
implementation. A small doctest harness extracts ` ```egg ` blocks from the guide and checks
them three ways: **smoke** (compiles and runs), **output** (stdout matches a paired fence), and
**error** (the checker produces a diagnostic containing a paired fence's text — so the guide can
demonstrate *and prove* the type checker / exhaustiveness messages).

This is the first of the two-part "make Omelette presentable" cluster; the **static website +
browser playground** is a separate follow-up cycle that will present this guide's content.

## Goals

- A trustworthy, learnable language guide — terse prose, maximal runnable examples.
- Every example verified on every `luajit spec/run.lua` run and in CI; a broken example fails the build.
- Examples are **self-contained** (each block is a complete program) so they are copy-pasteable.
- The doctest harness's own correctness is unit-tested (it genuinely catches drift).

## Non-Goals (deferred)

- The **static website / GitHub Pages / Fengari playground** — the follow-up cycle.
- Multi-file docs, API reference generation, or a docs site generator — a single `docs/guide.md` for now.
- Shared/growing context across blocks (a REPL-session model) — blocks are independent.
- Verifying examples in READMEs or specs — only `docs/guide.md`.

## Decisions

| Decision | Choice |
|---|---|
| Content | a single **`docs/guide.md`**, terse + example-driven |
| Example language tag | ` ```egg ` fenced blocks |
| Expected output | a **paired following fence** (` ```output ` / ` ```error `), not inline markers |
| Block modes | **smoke** (egg alone), **output** (egg + `output` fence), **error** (egg + `error` fence) |
| Block scope | **self-contained** — each block is a complete program |
| Verification home | `spec/` (runs with `luajit spec/run.lua`, hence CI) |

## Block Conventions

An ` ```egg ` block is paired with the **immediately following** fenced block if that fence's
info-string is `output` or `error`; otherwise the egg block is smoke-only.

- **smoke** — ` ```egg ` alone → `compiler.eval(code)` must succeed (no parse/compile/runtime error).
  ````
  ```egg
  let add x y = x + y
  print(add(2, 3))
  ```
  ````
- **output** — ` ```egg ` + ` ```output ` → run capturing `print`; captured stdout (trimmed) must
  equal the `output` fence content (trimmed).
  ````
  ```egg
  print(add(2, 3))
  ```
  ```output
  5
  ```
  ````
- **error** — ` ```egg ` + ` ```error ` → `compiler.check(code)` must return ≥1 diagnostic whose
  concatenated messages contain the `error` fence's text (substring match).
  ````
  ```egg
  type Shape = | Circle { radius } | Origin
  let area s = match s with | Circle { radius } -> radius
  ```
  ```error
  non-exhaustive match on 'Shape': missing Origin
  ```
  ````

Rendering note: `egg`/`output`/`error` are not known highlighters, so they render as plain
monospace blocks on GitHub/most renderers — which is fine (the website cycle can add an Omelette
grammar later).

## Harness Architecture

Split so the harness's own logic is unit-testable independently of the real guide.

**`spec/support/doctest.lua`** — pure-ish module:
- `extract(markdown) -> blocks` — scan lines for fenced blocks; return an ordered list of
  `{ code = <string>, mode = "smoke"|"output"|"error", expect = <string>|nil, line = <int> }`.
  An `egg` block takes the following block as its expectation iff that block's info-string is
  `output` or `error`; a stray `output`/`error` block not preceded by `egg` is ignored (or, for
  robustness, may be surfaced as a harness error — see testing).
- `run_block(block) -> ok, detail` —
  - **smoke:** `local _, err = compiler.eval(block.code)`; `ok = err == nil`.
  - **output:** temporarily replace `_G.print` with a buffer-appending function (join args with
    a tab like real Lua `print`, then newline), `compiler.eval`, restore `print`; compare the
    trimmed buffer to the trimmed `expect`.
  - **error:** `local diags = compiler.check(block.code)`; `ok` iff some `diags[i].message`
    contains `block.expect` (substring). (Report failure if it compiles clean or the message
    differs.)
  - `detail` is a human-readable reason on failure (for the test message), including `block.line`.

**`spec/doctest_spec.lua`** — unit tests for `doctest.lua` using **inline fixture markdown
strings** (NOT the real guide), asserting the harness catches drift:
- `extract` pairs an `egg`+`output` and an `egg`+`error` correctly; an `egg` alone is smoke; an
  `egg` followed by a non-expectation fence stays smoke.
- `run_block` **passes** a correct smoke/output/error block **and fails** a wrong-output block, a
  smoke block that errors, and an `error` block whose program actually compiles clean or whose
  diagnostic doesn't contain the text.

**`spec/doc_guide_spec.lua`** — reads `docs/guide.md`, `extract`s it, and asserts every block
`run_block`s green; a failure names the offending block's line and reason.

## Content — `docs/guide.md`

Terse, example-driven, one concept per short section, each with at least one verified example.
Sections (in order):
1. **What is Omelette / install** — one paragraph; how to `run`/`build`/`check` (smoke or prose).
2. **Values & bindings** — `let`, `pub let`, immutability; an `output` example.
3. **Functions & partial application** — juxtaposition headers, `f(x)` calls, `_` holes; `output`.
4. **Pipes** — `|>`; `output`.
5. **Control flow** — `if`/`then`/`else` as an expression; `output`.
6. **Pattern matching** — `match`, literals, variables, array/record destructuring, guards; `output`.
7. **Comprehensions & ranges** — list/dict comprehensions, `[a to b]`; `output`.
8. **Sum types** — `type` declarations, constructors, constructor patterns; `output`.
9. **Optional typing & exhaustiveness** — annotations, `omelette check`; at least one **`error`**
   example (a type mismatch) and one **`error`** example (a non-exhaustive match).
10. **Standard library tour** — `std.list` / `std.string` / `std.table` highlights; `output`.
11. **Lua interop** — calling Lua globals, `require`, `lua "..."`; smoke or `output`.

Every fenced `egg` example must pass the harness. The guide is the deliverable; the harness is
the guarantee it stays true.

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), existing harness.

- **`doctest.lua` unit tests** (`spec/doctest_spec.lua`): extraction pairing (all three modes +
  stray-fence handling); `run_block` passes correct blocks and **catches** each failure kind
  (wrong output, erroring smoke, non-erroring `error` block, wrong error text). This is the proof
  the doctest is not vacuous.
- **Guide verification** (`spec/doc_guide_spec.lua`): every `egg` block in `docs/guide.md` passes;
  a deliberately broken example (checked transiently during development) makes the suite red.
- **No regression:** all prior tests stay green; the new specs are additive.

## File Touchpoints

- Create: `docs/guide.md` (Task 2 fills it; Task 1 seeds it with a few real examples covering all
  three modes).
- Create: `spec/support/doctest.lua` (`extract` + `run_block`).
- Create: `spec/doctest_spec.lua` (harness unit tests, inline fixtures).
- Create: `spec/doc_guide_spec.lua` (verifies `docs/guide.md`).

No changes to the compiler, lexer, parser, codegen, typecheck, CLI, or CI config (the guide is
verified through the existing `spec/run.lua` that CI already runs).

## Deferred (record in `docs/DEFERRED.md`)

- **Static website + Fengari playground** (the presentation cycle) — will render this guide.
- **README overhaul** pointing at the guide; an Omelette highlighter grammar; multi-page docs;
  verifying README/spec examples too.
