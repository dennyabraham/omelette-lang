# Changelog

All notable changes to Omelette are documented here (Keep a Changelog format).

## [0.1.5]
First release actually published to LuaRocks.
- CI: the LuaRocks publish step now installs a JSON library (`dkjson`) that `luarocks upload` requires (0.1.4 cut a GitHub Release but failed to upload without it).
- Carries the 0.1.4 fixes: the destructuring-`let` checker crash fix, and the release job attaching to the `release` environment.

## [0.1.4]
Cut a GitHub Release but did not publish to LuaRocks (the upload step lacked a JSON library — fixed in 0.1.5).
- Fixed: `omelette check` no longer crashes on destructuring `let` bindings (the checker assumed every `let` has a name).
- Release CI now attaches to the `release` environment (and its allowlist includes `canon`) so the `LUAROCKS_API_KEY` secret is available to the publish step.

(0.1.3 was tagged but never released — its release run was blocked by the environment policy; 0.1.4 supersedes it.)

## [0.1.2]
Maintenance release — no language changes since 0.1.1.
- CI: releases are now cut automatically when `omelette/init.lua`'s version changes (auto-tag → release), alongside the existing manual-tag path.

## [0.1.1]
Maintenance release — no language changes since 0.1.0.
- Version bump so the first LuaRocks-published release can be cut once the repository is public and `LUAROCKS_API_KEY` is set (the v0.1.0 GitHub Release was published while private, so it did not reach LuaRocks).

## [0.1.0]
Initial release of Omelette — a small ML-family language that transpiles to readable Lua 5.1.

### Language
- Lexer, parser, resolver, codegen, compiler, CLI, and REPL.
- Immutable values; output reads like hand-written Lua.
- List comprehensions, `[a to b]` ranges, key/value generators, `xs[i]` indexing, `#xs` length.
- Pattern matching with variable/array/record destructuring and `when` guards.
- `if` and `match` as first-class expressions.
- Sum / variant types (capitalized constructors, `{ __tag = … }` runtime rep) with structural
  exhaustiveness checking, construction validation, and constructor-pattern validation.
- Optional, erased type annotations with an opt-in `omelette check`.

### Standard library
- `std.list`, `std.string`, `std.table` — bundled into the single-file binary, so
  `require("std.*")` resolves from any working directory.

### Tooling & docs
- `omelette run` / `build` / `check`, a `.egg` require-hook, and a single-file distributable binary.
- A runnable guide (`docs/guide.md`) whose every example is compiled and run in CI.
- A static site with a browser playground (runs the real compiler client-side) and syntax highlighting.
