# Omelette — Static Website & Playground Design

**Date:** 2026-08-18
**Status:** Approved design, pre-implementation
**Depends on:** runnable documentation (`docs/guide.md`, PR #14 — must merge first); `build/amalgamate.lua`; the compiler modules + `std/*.egg`

## Summary

A dependency-light static website (GitHub Pages-ready) presenting Omelette — a **landing**
page, the **guide** (rendered from the CI-verified `docs/guide.md`), and a browser
**playground** that runs the real compiler client-side via **Fengari** (a Lua VM in JS). No
npm/framework: hand-written HTML/CSS/JS, vendored single-file libraries, and a small
`site/build.lua` that assembles `site/dist/`.

The site is **built and reviewed locally; it is NOT published** by this cycle. Publishing
(enabling GitHub Pages) is a deliberate later step, gated on **(a)** the owner's review and
**(b)** the iambic-pentameter rewrite of all prose. A `workflow_dispatch` Pages workflow is
included but Pages stays off.

## Goals

- A browsable 3-page site (landing / guide / playground) reviewable locally via a static server.
- The playground compiles + runs Omelette **entirely client-side** (Fengari), including
  `require("std.*")` (embedded stdlib), matching the guide's examples.
- Zero build dependencies beyond Lua (build) and vendored single-file JS (`fengari-web.js`, `marked.js`).
- The guide on the site is exactly the verified `docs/guide.md` (no drift).
- Nothing is published; review is entirely local/private.

## Non-Goals (deferred)

- **Iambic-pentameter rewrite** of all guide + site prose — a **pre-public gate**, blocked on the
  owner's review. (Recorded in `docs/DEFERRED.md`.)
- **Publishing** (enabling GitHub Pages) — requires a public repo (Free) or a paid plan for
  private-repo Pages; happens after review + the iambic rewrite.
- An Omelette **syntax highlighter** for code blocks; multi-page guide; search; analytics.
- Server-side anything (the playground is 100% client-side).

## Decisions

| Decision | Choice |
|---|---|
| Tooling | **No-build static** — plain HTML/CSS/JS + a small `site/build.lua`; no npm/SSG |
| Playground VM | **Fengari** (`fengari-web.js`, vendored) — runs the real compiler in the browser |
| Guide rendering | **client-side** via vendored `marked.js` (fetches `docs/guide.md`) — no Lua markdown parser |
| Playground stdlib | **embedded** `std/*.egg` + a browser searcher (so `require("std.*")` works) |
| Deploy | built + reviewed **locally**; `workflow_dispatch` Pages workflow present but **Pages off** |
| Publish gate | owner review **+** iambic-pentameter rewrite, on a later manual step |

## Site Structure

Three hand-written pages (shared CSS; minimal JS):
1. **`index.html` (landing)** — hero (Omelette is an ML-flavored language compiling to Lua 5.1),
   a short punchy code example, an install one-liner, links to Guide / Playground / GitHub.
2. **`guide.html`** — a shell that fetches `docs/guide.md` and renders it with `marked.js`.
   Code fences render as plain monospace (an Omelette highlighter is deferred).
3. **`play.html` (playground)** — a two-pane editor: an input `<textarea>` (seeded with a sample)
   and an output pane; buttons **Run** (eval, capture `print`), **Compiled Lua** (show
   `compile` output), **Check** (show `check` diagnostics). Loads Fengari + the browser bundle.

Repo layout under **`site/`**:
- `site/build.lua` — the build script (below).
- `site/src/` — `index.html`, `guide.html`, `play.html`, `style.css`, `play.js`.
- `site/vendor/` — `fengari-web.js`, `marked.js` (vendored single files, committed).
- `site/dist/` — build output (git-ignored; the deploy/review artifact).

## Build Script — `site/build.lua` (pure Lua, no deps)

Running `lua site/build.lua` (or `luajit`) produces `site/dist/`:
1. **Guide:** copy `docs/guide.md` → `dist/guide.md` (rendered client-side by `guide.html`).
2. **Browser bundle** → `dist/omelette-browser.lua` — an extension of `build/amalgamate.lua`:
   - `package.preload["omelette.<mod>"]` for **all** compiler modules — `lexer, errors,
     resolver, parser, codegen, typecheck, compiler, searcher, init` (**typecheck added** —
     it is missing from `build/amalgamate.lua` today and is required for `compiler.check`).
   - **Embed the stdlib:** for each `std/*.egg`, emit `__omelette_std["std.<name>"] = [[<source>]]`.
   - **Browser searcher:** install a `package.searchers` loader that, for a `require("std.<name>")`,
     looks up `__omelette_std`, compiles it via `omelette.compiler`, and returns the chunk. (The
     filesystem searcher's `./?.egg` roots are useless in a browser; this replaces them.)
   - **No `cli.main` auto-run** (the page drives `compile`/`eval`/`check`).
3. **Copy** `site/src/*` and `site/vendor/*` into `dist/`.

The bundle is plain Lua, so it loads in any Lua VM — including Fengari in the browser and luajit
in tests.

## Playground Wiring — `play.js`

- Include `fengari-web.js`; get a Lua state (`fengari.lua`, `fengari.lauxlib`, `fengari.lualib`).
- Load and run `omelette-browser.lua` in the state (sets up `package.preload` + the browser searcher).
- On **Run:** set the Lua-side `print` to append to a JS buffer, then in Lua
  `require("omelette.compiler").eval(userSrc)`; render the captured output (and any error).
- **Compiled Lua:** `require("omelette.compiler").compile(userSrc)` → show the Lua string.
- **Check:** `require("omelette.compiler").check(userSrc)` → render diagnostics (message + line).
- All in-page; errors are shown, never thrown to the console.

(The compiler already runs under Lua 5.4 in CI, and Fengari targets 5.3/5.4, so it runs in Fengari;
`compiler.lua`'s `_VERSION`-gated `load`/`loadstring` picks `load`, which Fengari provides.)

## Deploy — built, not published

- **Local review (default):** `lua site/build.lua` then `cd site/dist && python3 -m http.server 8000`
  → review at `http://localhost:8000`. (A local http server, not `file://`, so Fengari can load
  the bundle.) Entirely private; no deployment.
- **`.github/workflows/pages.yml`** — a **`workflow_dispatch`-only** job that runs `build.lua` and
  uploads `dist/` as a Pages artifact. It does **not** run on push, and **GitHub Pages stays
  disabled** in repo settings — so nothing publishes until the owner turns Pages on (after review
  + the iambic rewrite; note: Pages on a private repo needs a paid plan, else the repo goes public
  first).

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), existing harness. The site's *risky logic* is the
browser bundle — and it is plain Lua, so it's testable without a browser:

- **`spec/browser_bundle_spec.lua`:**
  - Run `site/build.lua` (or call its bundle-builder function) to produce the bundle string.
  - Load the bundle in the current Lua VM (a stand-in for Fengari), then:
    - `require("omelette.compiler").eval('print(1 + 2)')` runs (capture `print` → "3").
    - **Embedded stdlib resolves:** `require("omelette.compiler").eval('let l = require("std.list")\nprint(l.sum([1,2,3]))')` → "6" (proves the embedded-std browser searcher works with NO filesystem).
    - `require("omelette.compiler").check('let x: number = "hi"')` returns a diagnostic (proves
      typecheck is bundled — the gap this cycle fixes).
- **`spec/site_build_spec.lua`** (or folded in): running the build produces `dist/index.html`,
  `dist/guide.html`, `dist/play.html`, `dist/omelette-browser.lua`, `dist/guide.md`,
  `dist/style.css`, `dist/play.js`, and the vendored JS.
- **No regression:** all prior tests stay green; `build/amalgamate.lua` (CLI amalgam) is unchanged
  or, if `typecheck` is added there too, its existing amalgamate test still passes.
- **Manual:** the owner reviews the rendered site locally (HTML/CSS/playground UX).

## File Touchpoints

- Create: `site/build.lua`, `site/src/{index.html,guide.html,play.html,style.css,play.js}`,
  `site/vendor/{fengari-web.js,marked.js}`.
- Create: `spec/browser_bundle_spec.lua` (+ build-output assertions).
- Create: `.github/workflows/pages.yml` (`workflow_dispatch`-only).
- Modify: `.gitignore` (ignore `site/dist/`).
- Possibly modify: `build/amalgamate.lua` to also bundle `typecheck` (align the CLI amalgam with
  the browser bundle) — or leave it and note the divergence.

No changes to the compiler/lexer/parser/codegen/typecheck/CLI logic (the bundle only *packages*
them).

## Deferred (record in `docs/DEFERRED.md`)

- **Iambic-pentameter rewrite** of all guide + site prose — pre-public gate, owner review required.
- **Publishing** (enable GitHub Pages) — after review + iambic; needs public repo (Free) or paid plan.
- Omelette **syntax highlighting** in code blocks; a "copy" button; playground share-links;
  multi-page guide; the CLI amalgam's missing `typecheck` (if not fixed here).
