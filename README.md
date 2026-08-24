# Omelette

Omelette is a small ML that compiles to plain Lua 5.1. Values are immutable; the
output reads like hand-written Lua.

```egg
type Shape = | Circle { radius } | Origin
let area s =
  match s with
  | Circle { radius } -> 3 * radius * radius
  | Origin            -> 0
print(area(Circle { radius = 2 }))   -- 12
```

## Commands

- `omelette run file.egg` — compile and execute.
- `omelette build file.egg` — compile to Lua and print or write it.
- `omelette check file.egg` — type-check and report diagnostics.

## Guide

Read `docs/guide.md`. Every example there is compiled and run in CI, so the
guide can't drift from the language.

## Develop

Run the tests: `luajit spec/run.lua`.

Design lives in `docs/superpowers/specs/`; the build plan in
`docs/superpowers/plans/`.
