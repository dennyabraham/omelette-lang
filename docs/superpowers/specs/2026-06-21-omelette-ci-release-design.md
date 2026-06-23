# Omelette — CI & Release Automation Design

**Date:** 2026-06-21
**Status:** Approved design, pre-implementation
**Depends on:** Omelette v1 + comprehensions (the test suite this CI runs)

## Summary

Add GitHub Actions **continuous integration** (run the test suite on every push/PR
under LuaJIT and Lua 5.4) and **release automation** (on a `vX.Y.Z` tag: validate,
test, build a single-file `omelette` script, publish a GitHub Release, and — when
public — publish to LuaRocks). Modeled on Fennel's approach: because the compiler is
pure Lua, the headline artifact is an amalgamated single-file script, distributed via
GitHub Releases and LuaRocks.

The release ritual stays tiny — bump `version`, add a changelog entry, tag — and the
workflow guarantees consistency across the three places a version appears (runtime,
git tag, LuaRocks).

## Goals

- Fast CI feedback on every push/PR: the full suite green under **LuaJIT and Lua 5.4**.
- One-command release via a git tag, producing a tested, version-consistent GitHub
  Release with a runnable single-file `omelette` attached.
- LuaRocks publishing that turns on automatically once the repo is public and a key is
  set, and is safely skipped while private.
- Release tooling (amalgamation, version check, changelog extraction) is itself
  **testable** and covered by the existing harness — not discovered-broken at release.

## Non-Goals (this cut)

- Standalone cross-platform binaries (Cosmopolitan/APE).
- GPG signing of releases / published checksums.
- A formatter, LSP, or any non-release tooling.
- Publishing to LuaRocks while the repository is private (the rockspec source URL must
  be publicly fetchable, so this is intentionally disabled).

## Key Decisions

| Decision | Choice |
|---|---|
| Release artifacts | GitHub Release + single-file `omelette` script + source archive + **LuaRocks** |
| CI matrix | **LuaJIT and Lua 5.4** |
| Version source of truth | `omelette/init.lua` `version`; the `vX.Y.Z` tag must match (validated) |
| Release trigger | a pushed git tag matching `v*` |
| LuaRocks publish | **conditional** — only when repo is public AND `LUAROCKS_API_KEY` secret is set |
| Single-file build | in-repo `build/amalgamate.lua` using `package.preload` bundling |
| Distribution source | `git+https://…` with the tag (no tarball hash needed) |

## Components

| File | Responsibility |
|---|---|
| `.github/workflows/ci.yml` | Push/PR: run `spec/run.lua` under LuaJIT and Lua 5.4 + an amalgamation smoke step |
| `.github/workflows/release.yml` | Tag `v*`: validate → test → build → GitHub Release → (conditional) LuaRocks |
| `build/amalgamate.lua` | `build() -> string`: bundle `omelette/*.lua` into one runnable script |
| `scripts/check-version.lua` | `check(tag, version) -> ok, msg`: assert the tag matches `init.lua` |
| `scripts/changelog.lua` | `extract(text, version) -> section`: pull a version's notes from the changelog |
| `rockspecs/omelette.rockspec.template` | LuaRocks spec; `@VERSION@`/`@TAG@` substituted at release |
| `CHANGELOG.md` | Keep-a-Changelog format; starts with `## [0.1.0]` (v1 + comprehensions) |
| `.gitignore` | add `dist/` (built artifact) |

## Versioning Model

`omelette/init.lua`'s `version` field is the single source of truth (it is already read
at runtime via `require("omelette").version`). A release is cut by:

1. Bump `version` in `omelette/init.lua`.
2. Add a `## [X.Y.Z]` section to `CHANGELOG.md`.
3. Commit, then `git tag vX.Y.Z` and push the tag.

The release workflow runs `scripts/check-version.lua`, which **fails the release** if the
tag's `X.Y.Z` does not exactly equal `init.lua`'s version. The rockspec version and the
GitHub Release both derive from that one validated number, so runtime, tag, and LuaRocks
can never disagree.

## CI Workflow (`.github/workflows/ci.yml`)

- **Triggers:** `push` and `pull_request`.
- **Job:** matrix over the interpreters `luajit` and `lua 5.4`, installed via the
  `leafo/gh-actions-lua` action (which puts the chosen interpreter on `PATH` as `lua`).
- **Steps:** checkout → setup Lua (matrix) → `lua spec/run.lua` (full suite must pass).
- **Amalgamation smoke step:** build `dist/omelette` via `build/amalgamate.lua` and run
  it against `spec/fixtures/hello.egg`, asserting the output contains `function M.greet`
  — so amalgamation breakage is caught on every push, not only at release.
- No LuaRocks or release steps here — CI stays fast for PR feedback.

## Release Workflow (`.github/workflows/release.yml`)

- **Trigger:** `push` of a tag matching `v*`.
- **Sequential job** (job-level env: `HAS_ROCKS_KEY: ${{ secrets.LUAROCKS_API_KEY != '' }}`):
  1. **Checkout** (full history + tags).
  2. **Setup LuaJIT.**
  3. **Validate version** — `luajit scripts/check-version.lua "$GITHUB_REF_NAME"`; fail
     on mismatch with `init.lua`.
  4. **Test** — `luajit spec/run.lua`; never release red.
  5. **Build** — `dist/omelette` from `build/amalgamate.lua`; `chmod +x`.
  6. **Smoke-test the artifact** — run `dist/omelette build spec/fixtures/hello.egg` and
     assert it works standalone.
  7. **Extract notes** — `scripts/changelog.lua` pulls the `## [X.Y.Z]` section.
  8. **GitHub Release** — create the release for the tag with those notes and attach
     `dist/omelette`. **Always runs.** (GitHub auto-attaches source archives.)
  9. **LuaRocks publish — conditional.** Render `rockspecs/omelette.rockspec.template`
     with the validated version + tag, then `luarocks upload <rendered>.rockspec
     --api-key=$LUAROCKS_API_KEY`. Step guard:
     `if: ${{ env.HAS_ROCKS_KEY == 'true' && github.event.repository.private == false }}`.
     Skipped while private or unkeyed; self-enables when both hold.

## Amalgamation (`build/amalgamate.lua`)

Exposes `build() -> string` (so it is unit-testable, not only a script). It emits, for
each module in a fixed list (`lexer, errors, resolver, parser, codegen, compiler,
searcher, repl, cli, init`):
```lua
package.preload["omelette.<name>"] = function(...)
  -- verbatim contents of omelette/<name>.lua
end
```
followed by a bootstrap `return require("omelette.cli").main(arg)` and a
`#!/usr/bin/env lua` shebang at the top. Because every module is registered in
`package.preload`, the internal `require("omelette.x")` calls resolve with no
filesystem access — the single file is self-contained. Module source is inlined verbatim
between `function(...)` and `end` (no escaping needed). The output is written to
`dist/omelette` (gitignored).

Notes:
- Preload registration order is irrelevant (entries are lazy; `require` runs them on
  demand). The trailing bootstrap drives the CLI.
- The existing `bin/omelette` path-hack is harmless under a LuaRocks install: it prepends
  a non-matching relative path, and `require` falls through to the installed Lua tree.
  One `bin/omelette` therefore works both from the repo and when installed.

## Rockspec (`rockspecs/omelette.rockspec.template`)

```
rockspec_format = "3.0"
package = "omelette"
version = "@VERSION@-1"
source = {
  url = "git+https://github.com/dennyabraham/omelette-lang.git",
  tag = "@TAG@",
}
description = {
  summary = "An ML-flavored language that transpiles to readable Lua 5.1",
  homepage = "https://github.com/dennyabraham/omelette-lang",
  license = "MIT",
}
dependencies = { "lua >= 5.1" }
build = {
  type = "builtin",
  modules = {
    ["omelette"]          = "omelette/init.lua",
    ["omelette.lexer"]    = "omelette/lexer.lua",
    ["omelette.errors"]   = "omelette/errors.lua",
    ["omelette.resolver"] = "omelette/resolver.lua",
    ["omelette.parser"]   = "omelette/parser.lua",
    ["omelette.codegen"]  = "omelette/codegen.lua",
    ["omelette.compiler"] = "omelette/compiler.lua",
    ["omelette.searcher"] = "omelette/searcher.lua",
    ["omelette.repl"]     = "omelette/repl.lua",
    ["omelette.cli"]      = "omelette/cli.lua",
  },
  install = { bin = { omelette = "bin/omelette" } },
}
```
The workflow substitutes `@VERSION@` and `@TAG@`. The `git+` source means no tarball
hash to compute.

## Testing Strategy

Release tooling is built as testable Lua modules, exercised by the existing harness under
`luajit` (`luajit spec/run.lua`), plus a CI integration step:

- `spec/check_version_spec.lua` — `check(tag, version)`: matching `v1.2.3`/`1.2.3` → ok;
  mismatch → not ok with a message; malformed tag (`1.2.3`, `vx`) → not ok.
- `spec/changelog_spec.lua` — `extract(text, version)`: returns the section between
  `## [X.Y.Z]` and the next `## [`; missing version → nil/empty.
- `spec/amalgamate_spec.lua` — `build()` contains the `package.preload` wrappers and the
  bootstrap; **behavioral:** `load()` the bundled string, run it in a sandbox, and
  smoke-compile `hello.egg` to prove the single-file artifact works.
- CI runs an integration step building `dist/omelette` and running it on a fixture.
- The workflow YAML is not unit-tested, but it orchestrates the above tested scripts.

## Prerequisites / Sequencing

- These files target `canon`. The **comprehensions branch (review-approved) should merge
  to `canon` first**, then this CI/release work branches off the updated `canon`.
- To enable LuaRocks later: make the repo public, create a luarocks.org account, generate
  an API key, and add it as the `LUAROCKS_API_KEY` repository secret. No workflow edit is
  required — the conditional step self-enables.
