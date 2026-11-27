# Branch Checking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Abstract

The checker gets one new method that checks an expression against a declared type. It
goes into `if` branches, `match` arms and a block's final expression, and reports each
branch that doesn't fit. Task 1 uses it for return and value annotations, Task 2 for
arguments to annotated parameters (pipes included), and Task 3 updates the roadmap,
guide and CHANGELOG.

## Contents

- [Header](#header)
- [Global Constraints](#global-constraints)
- [Review Focus](#review-focus)
- [Task 1: Check branches against return and value annotations](#task-1-check-branches-against-return-and-value-annotations)
- [Task 2: Check branches passed to annotated parameters](#task-2-check-branches-passed-to-annotated-parameters)
- [Task 3: Roadmap, guide and CHANGELOG](#task-3-roadmap-guide-and-changelog)

## Header

**Goal:** report `if`/`match` branches that don't fit a declared type, instead of
joining them to `any`.

**Architecture:** a new `Checker:check_against(node, env, want, branch)` in
`omelette/typecheck.lua` handles `if`, `match` and `block` by checking their
branches, and every other expression by synthesizing it and comparing. Callers that have
a declared type call it instead of `synth`. Callers keep their existing message for a
mismatch with no `if` or `match` on the path.

**Tech Stack:** Lua 5.1 / LuaJIT and Lua 5.4+; the repository's own spec harness.

**Spec:** `docs/superpowers/specs/2026-11-26-branch-checking-design.md`

## Global Constraints

- No new syntax. Nothing changes in generated Lua.
- Code with no annotations gets no new errors.
- Branch message: `<branch> is <T>, declared <D>` for annotations, and
  `<branch> is <T>, argument <i> expects <D>` for arguments. `<branch>` is
  `then branch`, `else branch` or `match arm`, the innermost branch holding the
  expression. Types are printed with `format_type` (the existing `tyname`).
- With no `if` or `match` on the path, the existing messages and positions stay:
  `function 'f' returns <T>, declared <D>` at the `let`, ahead of errors from inside
  the body; `'y' is declared <D> but assigned <T>`; `argument <i> expects <D>, got <T>`.
- Each expression is walked once, so each error inside a branch is reported once.
- `type_of` and `binding_of` are recorded for every expression, checked or not.
- Tests pass under `luajit spec/run.lua` and `lua spec/run.lua`.

## Review Focus

1. **A recursive call in a branch**, e.g. `let fact (n: number): number = if n == 0 then 1 else n * fact(n - 1)`:
   no error, since `fact`'s declared return type is `number`. Pinned in Task 1.
2. **A `match` with guards and a wildcard arm**: each arm is checked, and the
   exhaustiveness and pattern errors are reported once, not twice. Pinned in Task 1.
3. **A branch that is a lambda** against a declared function type, e.g.
   `let mk (b: boolean): (number) -> number = if b then fn x -> x else fn x -> x + 1`:
   no error, since a lambda's type has `any` parameters and return. Pinned in Task 1.
4. **A call with a `_` hole or the wrong argument count**, with an `if` argument: no
   branch errors, and the arity error is still reported once. Pinned in Task 2.
5. **Hover inside a checked branch**: the language server still finds the name and its
   type. Pinned in Task 1.

---

### Task 1: Check branches against return and value annotations

**Files:**
- Modify: `omelette/typecheck.lua` (`check_binding`, new `check_against`)
- Test: `spec/branch_check_spec.lua` (new; `spec/run.lua` finds `spec/*_spec.lua`)
- Test: `spec/lsp_server_spec.lua` (one hover test)

**Interfaces:**
- Produces: `Checker:check_against(node, env, want, branch) -> type`.
  - `want` is `{ type = D, arg = i }`, where `arg` is nil for an annotation and the
    argument number for a parameter.
  - `branch` is nil at the top, and `"then branch"`, `"else branch"` or `"match arm"`
    once an `if` or `match` is entered. A block passes on the `branch` it was given.
  - For a leaf, it synthesizes the type, reports the branch message if `branch` is set
    and the type is not consistent with `D`, and returns the synthesized type.
  - For `if` and `match` it returns `D`, so the caller's own check passes. For a block
    it returns what its final expression returned.
  - It records `type_of[node]` for `if`, `match` and `block` as `synth` would.

- [ ] **Step 1: Write the failing tests** in `spec/branch_check_spec.lua`, using the
  `diags(src)` style of `spec/typecheck_spec.lua` and asserting on every diagnostic's
  `message`, `line` and `col`:
  - `let f (x: number): number = if x > 0 then x else "neg"` gives one error,
    `else branch is string, declared number`, at the `"neg"` string.
  - The same with the wrong `then` branch gives `then branch is string, declared number`.
  - `let f (c: boolean): number = if c then "a" else "b"` gives exactly two errors.
  - `let m (v: number): number = match v with | 1 -> 1 | _ -> "x"` gives one error,
    `match arm is string, declared number`, at `"x"`.
  - A match with a `when` guard arm and a `_` arm, one wrong: one branch error. A
    non-exhaustive match on a declared sum type with a wrong arm: the branch error plus
    exactly one exhaustiveness error (Review Focus 2).
  - `let y: number = if c then 1 else "a"` gives `else branch is string, declared number`.
  - Nesting: `if a then (match v with | 1 -> 1 | _ -> "x") else 2` against `number`
    reports `match arm …` on `"x"`. A block whose final expression is an `if` with a
    wrong `else` reports `else branch …`.
  - `let f (x: number): number = if x > 0 then x else nil` gives
    `else branch is nil, declared number`.
  - A branch calling an unannotated function gives no error.
  - Review Focus 1 (recursive `fact`) and 3 (lambda branches): no errors.
  - Unchanged: `let y = if c then 1 else "a"` and the same `match` give no errors; a
    block body with no `if`/`match` whose result is wrong gives
    `function 'f' returns string, declared number` at the `let`.
  - Once only: `let f (c: boolean): number = if c then "a" + 1 else 2` gives exactly one
    error (the arithmetic one; `"a" + 1` is `number`).

- [ ] **Step 2: Run** `luajit spec/run.lua`. Expected: the new branch tests FAIL with no
  diagnostics; the "unchanged" and Review Focus 1/3 tests pass already.

- [ ] **Step 3: Implement `check_against`**, and in `check_binding` use it for a
  function body when `ret_type` is set and for a value when `value_type` is set. The
  existing return-mismatch insertion at `mark + 1` and the value-mismatch message stay
  as they are, applied to the type `check_against` returns.

- [ ] **Step 4: Add the hover test** (Review Focus 5) to `spec/lsp_server_spec.lua`:
  in `let n : number = 1\nlet f (c: boolean): number = if c then n else 0`, hover on
  the `n` in the `then` branch shows `n : number`.

- [ ] **Step 5: Run** `luajit spec/run.lua` and `lua spec/run.lua`. Expected: all pass,
  and `omelette check` (via `luajit bin/omelette check`) on each `std/*.egg` reports
  nothing.

- [ ] **Step 6: Commit** `feat(typecheck): check if/match branches against return and value annotations`.

### Task 2: Check branches passed to annotated parameters

**Files:**
- Modify: `omelette/typecheck.lua` (`synth_call`)
- Test: `spec/branch_check_spec.lua`

**Interfaces:**
- Consumes: `check_against` from Task 1, called with `want = { type = param, arg = i }`.
- `synth_call(fnnode, args, callnode, env)` keeps its signature. Holes are found from
  `args` before any argument is walked. When the callee has a function type, the call
  has no hole and the argument count matches, each argument is walked with
  `check_against`, and the existing `argument <i> expects …, got …` check is applied
  to what it returns. Otherwise each argument is synthesized as now.

- [ ] **Step 1: Write the failing tests:**
  - With `let g (n: number): number = n`, `let r (c: boolean) = g(if c then 1 else "a")`
    gives `else branch is string, argument 1 expects number` at `"a"`.
  - Pipe: `let r (c: boolean) = (if c then 1 else "a") |> g` gives the same message.
    With `let h (a: string) (n: number): number = n`,
    `let r (c: boolean) = "s" |> h(if c then 1 else "a")` gives
    `else branch is string, argument 2 expects number`.
  - Review Focus 4: with `let add (x: number) (y: number): number = x + y`,
    `add(_, if c then 1 else "a")` gives no error, and `add(if c then 1 else "a")` gives
    exactly one error, the existing arity message.
  - Unchanged: `g("a")` still gives `argument 1 expects number, got string`.

- [ ] **Step 2: Run** `luajit spec/run.lua`. Expected: the branch-argument and pipe tests
  FAIL; the others pass.

- [ ] **Step 3: Implement** the `synth_call` change described above.

- [ ] **Step 4: Run** `luajit spec/run.lua` and `lua spec/run.lua`. Expected: all pass.

- [ ] **Step 5: Commit** `feat(typecheck): check if/match branches passed to annotated parameters`.

### Task 3: Roadmap, guide and CHANGELOG

**Files:**
- Modify: `docs/ROADMAP.md`, `docs/guide.md`, `CHANGELOG.md`

- [ ] **Step 1: Guide.** In "Optional typing and exhaustiveness", after the
  `let x: number = "hi"` example, add an `egg` example
  `let sign (x: number): number = if x > 0 then 1 else "negative"` followed by an
  `error` block `else branch is string, declared number`, with one sentence saying
  branches are checked against the declared type.

- [ ] **Step 2: Roadmap.**
  - Remove "Bidirectional branch checking" from optional typing cycle 2, and add it to
    the Shipped "Types" line.
  - Add, before "Collection types": **Optional types** — `number?` for a value that may
    be `nil`. `std/list.egg`'s `min`, `max`, `find` and `index_of` return `nil` when
    there is nothing to return, so they need it before the standard library is typed.
  - Update the "Last updated" line.

- [ ] **Step 3: CHANGELOG.** Add an `[Unreleased]` section above `[0.3.1]` with:
  `omelette check` reports an `if` branch or `match` arm whose type doesn't fit a
  declared return type, value annotation or annotated parameter. It used to give the
  whole `if` or `match` the type `any`.

- [ ] **Step 4: Run** `luajit spec/run.lua` and `lua spec/run.lua`. Expected: all pass,
  including the guide's example check.

- [ ] **Step 5: Commit** `docs: branch checking in the guide, roadmap and changelog`.
