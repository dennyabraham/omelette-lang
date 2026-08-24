# Omelette — Stdlib Distribution (Self-Contained Binary + LuaRocks) Design

**Date:** 2026-08-24
**Status:** Approved design, pre-implementation
**Depends on:** the CLI amalgam + searcher + rockspec (all merged); blocks the v0.1.0 tag.

## Summary

Make `require("std.*")` resolve **without a repo checkout**, in both distribution
channels. Today the `.egg` searcher only resolves modules relative to the current
working directory (`./?.egg`, `./?/init.egg`), and `build/amalgamate.lua` bundles the
compiler modules but not `std/`. So the shipped single-file `omelette` binary — and a
future LuaRocks install — can compile std-free programs anywhere but fail on any
`require("std.list")` unless run from the repo root.

Fix: compile `std/*.egg` → Lua **at build time** (nothing generated is committed;
`std/*.egg` stays the sole source of truth) via one shared helper, and wire the compiled
output into each channel — `package.preload` for the single-file amalgam, installed
`std/*.lua` modules for LuaRocks.

## Goals

- `require("std.list")` / `std.string` / `std.table` resolve from **any** working
  directory when using the shipped `dist/omelette` binary.
- A LuaRocks install exposes the same std modules (via normal `package.path` resolution)
  and includes the currently-missing `omelette.typecheck` module.
- `std/*.egg` remains the only committed source of truth; no generated `.lua` is committed.
- A user's own project-local `.egg` modules still resolve via the existing searcher.
- No runtime compilation of std on the hot path; the amalgam carries compiled Lua.

## Non-Goals (deferred)

- Verifying the LuaRocks command-build **end-to-end** (`luarocks build` / `luarocks
  install`). It is gated off while the repo is private and cannot run for 0.1.0; it is
  written correct and validated structurally, first proven when the repo goes public.
- Bundling std as a separately-versioned package, or a std-module plugin path for
  third-party `.egg` libraries. Only the built-in `std.*` trio is addressed.
- Changing std's surface or contents.

## Background: why it fails today

`omelette/searcher.lua` registers a package searcher whose roots are
`{ "./?.egg", "./?/init.egg" }` — CWD-relative only. `std/list.egg` resolves as
`./std/list.egg`, which exists only inside the repo. `build/amalgamate.lua` bundles
`omelette/*.lua` into `package.preload` but never touches `std/`. The rockspec's
`build.modules` also omits `omelette.typecheck` (added to the amalgam earlier but not the
rock) and ships no std at all.

Verified reproduction: `dist/omelette run uses_stdlib.egg` from `/tmp` →
`module 'std.list' not found`. From the repo root → works (finds `./std/list.egg`).

## Architecture

Each compiled `std/*.egg` is a self-contained Lua chunk ending in `return M`, with **no
inter-std `require`s** (verified). That makes both wiring strategies trivial: the chunk is
a complete module body.

### Shared build helper — `build/build-std.lua`

A pure-Lua module (requires `omelette.compiler`) with the interface:

- `M.STD = { "std.list", "std.string", "std.table" }` — the module list, in a fixed order.
- `M.source(modname)` → reads `std/<leaf>.egg` (e.g. `std.list` → `std/list.egg`),
  returns the `.egg` source string. Raises on read failure.
- `M.compile(modname)` → returns the compiled Lua string for one module (asserts the
  compile succeeded; raises with the module name + diagnostic on failure).
- `M.compile_all()` → returns an ordered array of `{ module = <modname>, lua = <string> }`
  for every module in `M.STD`.
- `M.preload_block()` → returns a Lua source string:
  ```lua
  package.preload["std.list"]   = function(...) <compiled> end
  package.preload["std.string"] = function(...) <compiled> end
  package.preload["std.table"]  = function(...) <compiled> end
  ```
  Used by the amalgam. The compiled chunk's trailing `return M` becomes the preload
  function's return value.
- `M.write_lua(outdir)` → writes `<outdir>/std/<leaf>.lua` for each module (creating
  `<outdir>/std`), returns the list of written paths. Used by the LuaRocks build command.
- Direct run: `lua build/build-std.lua <outdir>` calls `M.write_lua(outdir)` and prints
  the written paths (the rock `build_command` entry point).

Reading `std/*.egg` and requiring `omelette.compiler` both resolve relative to CWD, which
is the repo root in every caller (amalgamate, the rock build, the tests).

### Channel ① — single-file amalgam (`build/amalgamate.lua`)

After emitting the `omelette.*` preload blocks and **before** the final
`os.exit(require("omelette.cli").main(arg))`, append `build_std.preload_block()`
(loaded via `dofile("build/build-std.lua")`, so its direct-run guard does not fire).
Result: `dist/omelette` carries the compiled std in `package.preload`. Lua's preload
searcher precedes the `.egg` searcher, so `require("std.list")` hits the embedded module
first, from any directory. `omelette/cli.lua` is unchanged — the `.egg` searcher still
installs and still resolves the user's own project-local `.egg` modules.

### Channel ② — LuaRocks (`rockspecs/omelette.rockspec.template`)

Switch `build.type` from `builtin` to `command` (rockspec_format 3.0), because std must
be compiled at install time and `builtin` cannot run a compile step:

- `build.build_command = "lua build/build-std.lua build-out"` — compiles
  `std/*.egg` → `build-out/std/*.lua` on the installing machine (the rock ships
  `build/build-std.lua`, `omelette/*.lua`, and `std/*.egg`, all fetched from the tag).
- `build.install_command` copies into LuaRocks' provided locations:
  - `omelette/*.lua` (including **`omelette/typecheck.lua`**) → `$(LUADIR)/omelette/`
  - `build-out/std/*.lua` → `$(LUADIR)/std/`
  - `bin/omelette` → `$(BINDIR)/`
  Uses the standard `$(LUADIR)` / `$(BINDIR)` substitutions and a portable `cp -R` /
  `install`-style copy (the existing build already shells `cp -R` for fonts, so shelling
  out in a build command is consistent with the repo).

After install, `require("std.list")` resolves to `$(LUADIR)/std/list.lua` via normal
`package.path` — no searcher and no CWD dependency. The searcher is still installed by the
CLI for user-project modules.

This channel is **written correct and structurally validated** (the rockspec parses; the
module/std/bin lists are asserted) but not exercised end-to-end until the repo is public
and `luarocks build` can run in CI.

## Error handling

- `build/build-std.lua` **raises** (non-zero exit) if any `std/*.egg` is missing or fails
  to compile, naming the module and the diagnostic — a broken build must fail loudly, not
  emit a binary with a silently-missing std module.
- The amalgam build already runs under the test suite's smoke test; a std compile failure
  surfaces there and in the release workflow's build step.
- At runtime nothing new can fail: preload/`package.path` resolution is standard Lua.

## Testing strategy

- **`spec/build_std_spec.lua`** (new): `compile_all()` returns all three modules; each
  compiled string `load()`s without error; `preload_block()` output `load()`s; a missing
  module raises. (Pure, fast, no subprocess.)
- **`spec/amalgamate_spec.lua`** (extend): add a case that builds the amalgam into a
  **temp dir outside the repo** (with no `./std/`), then runs a program doing
  `require("std.list")` there — asserting it now succeeds (the exact scenario that fails
  today). Mirror the file's existing `check`-in-tempdir case verbatim: spawn via
  `interp = (arg and arg[-1]) or "lua"` (never a hardcoded `luajit`; the Lua 5.4 CI leg has
  none) and capture the status with `; echo EXIT=$?`.
- **`spec/rockspec_spec.lua`** (new): render the template (substitute `@VERSION@`/`@TAG@`),
  load it as a Lua table, and assert `build.type == "command"`, that `build_command`
  invokes `build/build-std.lua`, and that `install_command` covers `omelette/typecheck.lua`,
  the `std/*.lua` outputs, and `bin/omelette`. Structural only.
- The existing 291 tests stay green (the searcher and cli are unchanged in behavior).

## File touchpoints

- **Create:** `build/build-std.lua`; `spec/build_std_spec.lua`; `spec/rockspec_spec.lua`.
- **Modify:** `build/amalgamate.lua` (append `preload_block()`);
  `spec/amalgamate_spec.lua` (add the std-from-tempdir case);
  `rockspecs/omelette.rockspec.template` (command build + typecheck + std).
- **Unchanged:** `omelette/searcher.lua`, `omelette/cli.lua`, `std/*.egg`,
  `.github/workflows/release.yml` (the tag flow already builds + smoke-tests the amalgam).

## Ship sequencing (after this fix merges)

1. Rewrite the stale `## [0.1.0]` CHANGELOG entry to the real feature set: ML→Lua 5.1
   transpiler; lexer/parser/codegen/compiler/CLI/REPL; comprehensions, ranges, KV
   generators, indexing, length; pattern matching with destructuring + guards; `if`/`match`
   as expressions; sum/variant types with structural exhaustiveness checking; optional
   typing (`omelette check`); the runnable guide; the static site + browser playground with
   syntax highlighting; a **self-contained** stdlib (`std.list`/`string`/`table`).
2. Tag `v0.1.0` → the release workflow validates the tag against `init.lua` (already
   `0.1.0`), runs tests, builds + smoke-tests `dist/omelette`, extracts the CHANGELOG
   section, and cuts the GitHub Release. LuaRocks publish stays skipped while private.
3. Going public (repo public + `LUAROCKS_API_KEY` secret + enable Pages) and the first
   LuaRocks publish remain owner actions, tracked in `docs/DEFERRED.md`.

## Deferred (record in `docs/DEFERRED.md`)

- End-to-end LuaRocks verification (`luarocks build`/`install` in CI) once public.
- Clear the "Stdlib distribution / discovery" deferral entry (resolved by this cycle).
