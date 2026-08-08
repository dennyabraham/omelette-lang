# Omelette — `if` as a First-Class Expression Design

**Date:** 2026-08-07
**Status:** Approved design, pre-implementation
**Depends on:** richer pattern matching (the `gen_match` IIFE template; the `(`→`parse_expr_or_form` primary)

## Summary

Make `if` usable as a value sub-expression, mirroring `match`. Today a parenthesized
`(if c then a else b)` **parses** (the `(` primary routes through `parse_expr_or_form`) but
**fails at codegen** (`cannot emit expression of kind 'if'`). Add a `gen_if` IIFE handled in
`codegen.expr`, while **keeping** the existing clean statement-lowering for `if` in
binding/branch/return position (no closure in the common case).

## Goals

- `1 + (if c then a else b)`, `(if c then x else y) |> f`, `[ (if …) | x <- xs ]`, `f(if …)`
  (parenthesized) all compile and run.
- The common `let x = if c then a else b` (and `if` as a function-return / if-branch) keeps its
  existing non-closure lowering — generated Lua unchanged for those.

## Non-Goals

- Changing `if`'s statement-lowering (`gen_value`/`gen_fn_body`) — untouched.
- Making a *bare* (unparenthesized) `if` parse in operand position — as with `match`, you
  parenthesize `(if …)` in a sub-expression, ML-style.

## Design (Option A — hybrid)

Add a `gen_if` local next to `gen_match` in `omelette/codegen.lua`:
```lua
local function gen_if(node, ctx)
  return table.concat({
    "(function()",
    "  if " .. expr(node.cond, ctx) .. " then",
    gen_fn_body(node.then_branch, ctx, "    "),
    "  else",
    gen_fn_body(node.else_branch, ctx, "    "),
    "  end",
    "end)()",
  }, "\n")
end
```
- Reuses the existing `gen_fn_body` for each branch, so it is **falsy-safe** (returns the value
  from each branch) and lowers `if`/`match`/`block` branch bodies correctly.
- Wire it into `expr`, alongside the `match` case:
  ```lua
  if k == "if" then return gen_if(node, ctx) end
  ```
- **Do not** modify `gen_value`'s `if` branch or `gen_fn_body`'s `if` branch. Those handle `if`
  in binding/branch/return position and are reached *before* `M.expr`, so the common cases keep
  their clean non-closure output; only a genuine sub-expression `if` (reached via `M.expr`)
  gets the IIFE.

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), existing harness.

- **Codegen golden:** `gen("(if c then 1 else 2)")` → the IIFE shape (`(function()`, `if c then`,
  `return 1`, `else`, `return 2`, `end)()`).
- **Behavioral (compile + run):**
  - binop operand: `1 + (if n > 0 then 10 else 20)`;
  - pipe LHS: `(if c then 1 else 2) |> tostring`;
  - comprehension yield: `[ (if x > 0 then "p" else "n") | x <- xs ]`;
  - call argument: `tostring(if c then 1 else 2)` (parenthesized where the grammar needs it);
  - **falsy-safe:** `(if c then false else true)` returns exactly `false`/`true`;
  - nested: `(if a then (if b then 1 else 2) else 3)`.
- **Regression:** the common `let x = if c then a else b`, `if` as a function return, and `if` as
  an `if`/`match` branch still emit the existing non-closure Lua and behave (existing tests +
  a golden check that a let-bound `if` does NOT contain `(function()`).

## File Touchpoints

- `omelette/codegen.lua` — add `gen_if`; add the `if` case to `expr`. (`gen_value`/`gen_fn_body`
  untouched.)
- `spec/` — codegen-golden + behavioral tests for `if`-as-expression, and a regression golden
  that a let-bound `if` stays non-closure.

No changes to lexer, parser, typecheck, compiler, resolver, CLI, REPL, or searcher. (The
parser already parses `(if …)` via the `(`→`parse_expr_or_form` primary; typecheck already
synthesizes `if`.)

## Deferred note (`docs/DEFERRED.md`)

Removes the "`if` as a sub-expression" item — this closes it.
