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
- `omelette --version` — print the version.
- `omelette lsp` — run the language server on stdin/stdout, for editors.

## Editors

Neovim 0.11+: install [omelette.nvim](https://github.com/dennyabraham/omelette.nvim)
(`{ "dennyabraham/omelette.nvim" }` with lazy.nvim). It needs `omelette` 0.2.0 or
later on your `PATH`. Other editors can run `omelette lsp` as a language server for
`.egg` files: it provides diagnostics and semantic tokens.

## Guide

Read `docs/guide.md`. Every example there is compiled and run in CI, so the
guide can't drift from the language.

## Develop

Run the tests: `luajit spec/run.lua`.

Build and preview the site (landing, guide, playground): `lua site/build.lua
--serve`. See `site/README.md` for details.
