# Omelette — Playground E2E Tests (Playwright, CI-only) Design

**Date:** 2026-08-23
**Status:** Approved design, pre-implementation
**Depends on:** the static website + playground (PR #15 — must merge first); `site/build.lua`, `site/dist/`

## Summary

Add browser end-to-end tests (Playwright, Chromium) that validate the one part of the project
not yet verifiable without a browser: the **Fengari playground** — the JS↔Lua glue, the compiler
actually executing in Fengari, `fetch`/DOM/event wiring, and `marked` rendering of the guide.

The tests run **CI-only, in the disposable GitHub Actions runner** — never on a developer's
machine. This satisfies the isolation goal (no Docker, no browser install, no `node_modules`
locally; the ephemeral runner is the sandbox and is thrown away). Playwright uses its own pinned
Chromium (never the host's Chrome), and the browser dependency lives entirely inside a
self-contained `tests/e2e/` (its own `package.json`) so the product, build, and repo root stay
**npm-free**.

## Goals

- Verify in a real browser: play page loads and reports "Ready"; **Run** of the seeded example
  prints `27`; **Compiled Lua** shows real Lua; **Check** reports "No type errors"; a type
  mismatch and a non-exhaustive match produce the expected diagnostics; a runtime error is caught
  gracefully; a stdlib example runs; the **guide** renders (marked); the landing page loads.
- Zero developer-machine footprint: e2e runs only in CI.
- The npm/browser dependency is isolated to `tests/e2e/`; nothing else in the repo gains an npm dep.

## Non-Goals (deferred)

- **Local execution** (Docker image / `make e2e`) — CI-only for now.
- Firefox/WebKit; visual-regression/screenshot diffing; performance budgets.
- Making the e2e a *required* status check — that is a GitHub branch-protection setting the owner
  controls; this cycle only provides the workflow + signal.
- Testing the published site (nothing is published).

## Decisions

| Decision | Choice |
|---|---|
| Framework | **Playwright** (`@playwright/test`), Chromium only |
| Where it runs | **CI-only**, ephemeral GitHub Actions runner (no local run, no Docker) |
| Dependency isolation | a self-contained **`tests/e2e/`** with its own `package.json`; repo root stays npm-free |
| Serving under test | Playwright `webServer` = `python3 -m http.server` over the lua-built `site/dist/` |
| CI gating | workflow runs on push/PR (path-filtered); "required to merge" is the owner's branch-protection setting |

## Architecture

```
tests/e2e/
  package.json          # devDependency: @playwright/test (the ONLY npm in the repo)
  playwright.config.ts  # chromium project; webServer serves ../../site/dist
  playground.spec.ts    # the playground cases
  pages.spec.ts         # landing + guide render
.github/workflows/e2e.yml
```

- **`playwright.config.ts`:** one `chromium` project; `use.baseURL = http://localhost:8137`;
  `webServer = { command: "python3 -m http.server 8137 --directory ../../site/dist", url:
  "http://localhost:8137/index.html", reuseExistingServer: true }`. Retries: 1 (guards browser
  startup flake without hiding real failures).
- The site is built by a **prior lua step** (`lua site/build.lua` → `site/dist/`); Playwright only
  serves + drives it (the Playwright/runner has `python3`, no lua needed at test time).

## Test Cases

**`playground.spec.ts`** (navigates to `/play.html`; the playground exposes `#editor`,
`#output`, and buttons `#run`, `#lua`, `#check`):
- **loads:** `#output` reaches "Ready" (the bundle loaded into Fengari) — the core proof the
  JS↔Lua glue binds and the compiler runs in Fengari.
- **Run (seeded):** click `#run` → `#output` contains `27` (the seeded `area(Circle{radius=3})`).
- **Compiled Lua:** click `#lua` → `#output` contains `local M` (real generated Lua).
- **Check (clean):** click `#check` → `#output` contains "No type errors".
- **Check (type mismatch):** set `#editor` to `let x: number = "hi"`, click `#check` → contains
  `number`.
- **Check (non-exhaustive):** set `#editor` to a declared type + a match missing a constructor →
  contains `missing`.
- **Run (runtime error):** set `#editor` to a program that errors at runtime → `#output` contains
  `[error]` (caught, not a blank/console crash).
- **Run (stdlib):** set `#editor` to `let l = require("std.list") print(l.sum([1, 2, 3, 4]))`,
  click `#run` → contains `10` (embedded stdlib resolves in the browser).

**`pages.spec.ts`:**
- **landing:** `/index.html` loads; heading contains "Omelette"; links to Guide/Playground exist.
- **guide renders:** `/guide.html` — after load, the `#guide` element contains rendered HTML from
  `docs/guide.md` (e.g. an `<h1>`/`<h2>` is present and the raw `# ` markdown is gone), proving
  `fetch(guide.md)` + `marked` ran.

Each expected value (27, "No type errors", "missing", 10, …) is already confirmed correct against
the compiler via the playground's Lua drivers, so these assertions are pinned to known-good output.

## CI — `.github/workflows/e2e.yml`

Runs on `push`/`pull_request` **path-filtered** to `site/**`, `tests/e2e/**`, `omelette/**`,
`std/**`, `docs/guide.md` (so it fires when anything the playground bundles changes). Steps
(ubuntu-latest, the disposable runner):
1. checkout
2. `leafo/gh-actions-lua@v13` (luajit) → `lua site/build.lua` (produces `site/dist/`)
3. `actions/setup-node@v4`
4. `cd tests/e2e && npm ci`
5. `npx playwright install --with-deps chromium`
6. `npx playwright test`
7. on failure: upload the Playwright HTML report as an artifact (for debugging).

Everything happens in the ephemeral runner; nothing is installed on any developer machine, and
nothing publishes.

## Verification Model (honest limitation)

The browser tests **cannot be run in the authoring environment** (no Docker/browser, and running
Playwright natively would install a browser locally — the very thing we're avoiding). So:
- **Locally verifiable now:** `lua site/build.lua` produces `dist/`; `playwright.config.ts` and the
  workflow YAML are well-formed; the spec files parse (via `node --check` / `tsc --noEmit` if
  available); the selectors (`#editor`, `#output`, `#run`, `#lua`, `#check`, `#guide`) match the
  built HTML; expected outputs match the verified Lua-driver results.
- **Real verification:** the **CI run** on push — the `e2e` job going green is the proof the
  playground works in a real browser. This is inherent to CI-only and is the acceptance signal.

## File Touchpoints

- Create: `tests/e2e/package.json`, `tests/e2e/playwright.config.ts`,
  `tests/e2e/playground.spec.ts`, `tests/e2e/pages.spec.ts`.
- Create: `.github/workflows/e2e.yml`.
- Modify: `.gitignore` (ignore `tests/e2e/node_modules/`, `tests/e2e/playwright-report/`,
  `tests/e2e/test-results/`).
- No changes to the compiler, the site, or the existing Lua test suite / CI.

## Deferred (record in `docs/DEFERRED.md`)

- **Local e2e run** via the Playwright Docker image (`make e2e`) for those with Docker.
- Firefox/WebKit projects; visual-regression snapshots; a shared-link/permalink test once the
  playground gains that feature.
- Making e2e a required merge check (owner branch-protection setting).
