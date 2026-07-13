# Omelette — Top-Level Mutual Recursion Design

**Date:** 2026-07-13
**Status:** Approved design, pre-implementation
**Depends on:** v1 + the stdlib codegen change (top-level bindings as locals + `M` alias)

## Summary

Make top-level bindings in a module mutually referenceable in any order by
**forward-declaring all top-level locals**, then assigning each. This enables top-level
**mutual recursion** (`is_even`/`is_odd`) and **forward references** (a function calling
a sibling defined below it), removing the current "definitions must precede uses"
limitation that forced the standard library to be hand-ordered.

## Motivation & Context

`M.program` currently emits each top-level binding as `local function f`/`local x` in
source order. Because a Lua `local function` is not in scope before its own definition, a
function that references a *later*-defined sibling compiles cleanly but fails at runtime
with a nil-global call. Top-level mutual recursion is impossible today. This was flagged
as a latent footgun in the standard-library whole-branch review (`docs/DEFERRED.md`).

## Goals

- Top-level functions may reference each other **in any order** (mutual recursion,
  forward references).
- No change to observable behavior for already-correct (dependency-ordered) modules.
- The change is isolated to the module-level emission; block-internal `let`s are untouched.

## Non-Goals

- **Value-binding forward references** — a *value* binding that eagerly reads a
  not-yet-computed sibling (`let a = b()` where `b`'s value isn't ready when `a` runs)
  still fails at runtime. This is inherent (you cannot use an uncomputed value); the fix
  targets *function* mutual recursion.
- Hoisting or reordering; no change to evaluation order of value bindings.

## Design

Change **only** `M.program` (in `omelette/codegen.lua`). Two-pass emission:

1. **Forward-declare:** collect the names of all top-level `let` bindings (in order) and
   emit a single declaration line: `local <name1>, <name2>, …, <nameN>`.
2. **Assign:** emit each binding as an assignment to its already-declared local (i.e. the
   same as today's `gen_local_let` output but **without the leading `local`**):
   - function → `function <name>(<params>)` … `end`
   - simple value → `<name> = <expr>`
   - `if`/`match`/`block`-valued → lower directly into `<name>` (no `local <name>` line,
     since it is already declared)
   - `pub` binding → additionally `M.<name> = <name>` (unchanged)
3. Bare top-level expressions (non-`let`) and the trailing `return M` are unchanged.

Because every top-level binding is a module-level local declared up front, each function
closes over its siblings as upvalues no matter the order.

```
-- omelette (defined in this order; is_odd used before it is defined)
pub let is_even n = if n == 0 then true else is_odd(n - 1)
pub let is_odd n = if n == 0 then false else is_even(n - 1)
```
```lua
-- compiled Lua
local M = {}
local is_even, is_odd
function is_even(n) ... is_odd(n - 1) ... end
function is_odd(n)  ... is_even(n - 1) ... end
M.is_even = is_even
M.is_odd = is_odd
return M
```

### Isolation

`gen_local_let` is also used for `let`s **inside** blocks/function bodies. Those must
keep emitting `local …` (they are correctly block-scoped and need no forward declaration).
Therefore `gen_local_let` is **not** modified; the new assignment-form emission lives only
in `M.program` (a small top-level helper, e.g. `gen_top_assign`).

### Limitation (documented)

Lua caps a function scope at **200 local variables**. The module chunk is one scope, so a
single `.egg` module cannot exceed ~200 top-level bindings. This is far beyond any
realistic module (the largest stdlib module has ~30 bindings); noted for completeness.

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), existing harness.

- **Update golden module-codegen tests** (`spec/codegen_module_spec.lua`): the emitted
  shape changes from `local function add(...) … M.add = add` to a leading
  `local add[, …]` forward-declaration + `function add(...) …` + `M.add = add`. Update the
  assertions to the new shape (use `:find` substring checks on the forward-decl line, the
  `function name(` form, and the `M.name = name` alias).
- **Keep all behavioral tests green** — `M.f` remains callable; existing recursion and
  stdlib behavior is unaffected.
- **Add behavioral tests:**
  - **Mutual recursion** — `is_even`/`is_odd` referencing each other, defined in
    **both** orders (is_even first, and is_odd first), returning correct values.
  - **Forward reference** — a `pub` function that calls a sibling defined *below* it in
    the source returns the correct value (would fail before this change).
- The stdlib modules (`std/*.egg`) are unchanged and stay green (still validly ordered;
  ordering is simply no longer required).

## File Touchpoints

- `omelette/codegen.lua` — `M.program`: forward-declare top-level locals, then assign
  (new top-level assignment helper; `gen_local_let` unchanged).
- `spec/codegen_module_spec.lua` — updated golden strings.
- `spec/compiler_spec.lua` (or a new `spec/mutual_recursion_spec.lua`) — mutual-recursion
  and forward-reference behavioral tests.

No changes to lexer, parser, resolver, compiler, CLI, REPL, searcher, or `std/*.egg`.
