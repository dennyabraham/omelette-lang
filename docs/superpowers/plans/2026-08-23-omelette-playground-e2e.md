# Omelette Playground E2E (Playwright, CI-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **PREREQUISITE:** PR #15 (static website) must be merged into `canon` first — the e2e tests target `site/dist/`, built by `lua site/build.lua`. Rebase this branch onto the updated `canon` before starting (so `site/` exists).
>
> **VERIFICATION MODEL:** the browser tests CANNOT be run in the authoring environment (no Docker/browser). Each task verifies what is checkable locally (JS syntax via `node --check`, the site builds, selectors match the built HTML, YAML/JSON valid). The real green/red signal is the **CI `e2e` job** on push. Do NOT claim the browser tests "pass" locally.

**Goal:** CI-only Playwright (Chromium) e2e tests that validate the Fengari playground (Run/Compiled-Lua/Check, runtime errors, stdlib) and the guide rendering, run entirely in the disposable GitHub Actions runner.

**Architecture:** A self-contained `tests/e2e/` (its own `package.json` — the repo's only npm) with `.js` Playwright specs; a `webServer` serves the lua-built `site/dist/`. A `.github/workflows/e2e.yml` builds the site (lua) then runs Playwright on an ephemeral runner. Nothing runs on a developer machine; nothing publishes.

## Global Constraints

- The product, build, and repo root stay **npm-free**; the only npm lives in `tests/e2e/`.
- Playwright specs are plain **`.js`** (not `.ts`) so `node --check` validates them with zero toolchain.
- **Chromium only.** Tests run **CI-only** (ephemeral runner); no local Docker/browser required or used.
- Expected outputs are pinned to already-verified compiler behavior: Run(seeded Circle radius 3)=`27`, stdlib `sum([1,2,3,4])`=`10`, Check-clean="No type errors", type mismatch→`number`, non-exhaustive→`missing`, runtime error→`[error]`.
- The playground DOM (from `site/src/play.html`): `#editor` (textarea), `#output`, buttons `#run` / `#lua` / `#check`; the guide page uses `#guide`.

---

### Task 1: The `tests/e2e/` Playwright project

**Files:**
- Create: `tests/e2e/package.json`, `tests/e2e/playwright.config.js`, `tests/e2e/playground.spec.js`, `tests/e2e/pages.spec.js`
- Modify: `.gitignore` (ignore the e2e node_modules / reports)

**Interfaces:**
- Consumes: the built `site/dist/` (from `lua site/build.lua`) served at `http://localhost:8137`.
- Produces: a runnable Playwright project (`npm ci && npx playwright test` in `tests/e2e/`).

- [ ] **Step 1: Create `tests/e2e/package.json`**

```json
{
  "name": "omelette-e2e",
  "private": true,
  "version": "0.0.0",
  "description": "Browser end-to-end tests for the Omelette playground (CI-only).",
  "scripts": { "test": "playwright test" },
  "devDependencies": { "@playwright/test": "^1.48.0" }
}
```

- [ ] **Step 2: Create `tests/e2e/playwright.config.js`**

```js
// Chromium-only; serves the lua-built site/dist over http (playground needs http, not file://).
const { defineConfig, devices } = require("@playwright/test");

module.exports = defineConfig({
  testDir: ".",
  timeout: 30000,
  retries: 1,                       // guard browser-startup flake without hiding real failures
  reporter: [["html", { open: "never" }], ["list"]],
  use: { baseURL: "http://localhost:8137", trace: "on-first-retry" },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: {
    // site/dist is built by the CI lua step before playwright runs
    command: "python3 -m http.server 8137 --directory ../../site/dist",
    url: "http://localhost:8137/index.html",
    reuseExistingServer: true,
    timeout: 30000,
  },
});
```

- [ ] **Step 3: Create `tests/e2e/playground.spec.js`**

```js
const { test, expect } = require("@playwright/test");

// The bundle loads asynchronously (fetch + Fengari); every test waits for "Ready".
test.beforeEach(async ({ page }) => {
  await page.goto("/play.html");
  await expect(page.locator("#output")).toContainText("Ready", { timeout: 20000 });
});

async function editAndClick(page, src, button) {
  await page.fill("#editor", src);
  await page.click(button);
}

test("Run: a Shape area program prints 27", async ({ page }) => {
  await editAndClick(page,
    "type Shape = | Circle { radius } | Origin\n" +
    "let area s = match s with | Circle { radius } -> 3 * radius * radius | Origin -> 0\n" +
    "print(area(Circle { radius = 3 }))",
    "#run");
  await expect(page.locator("#output")).toContainText("27");
});

test("Compiled Lua: shows real generated Lua", async ({ page }) => {
  await page.click("#lua");
  await expect(page.locator("#output")).toContainText("local M");
});

test("Check: a clean program reports no type errors", async ({ page }) => {
  await page.click("#check");
  await expect(page.locator("#output")).toContainText("No type errors");
});

test("Check: a type mismatch is reported", async ({ page }) => {
  await editAndClick(page, 'let x: number = "hi"', "#check");
  await expect(page.locator("#output")).toContainText("number");
});

test("Check: a non-exhaustive match is reported", async ({ page }) => {
  await editAndClick(page,
    "type T = | A { v } | B\nlet f t = match t with | A { v } -> v", "#check");
  await expect(page.locator("#output")).toContainText("missing");
});

test("Run: a runtime error is caught gracefully", async ({ page }) => {
  await editAndClick(page, "print(nope + 1)", "#run");
  await expect(page.locator("#output")).toContainText("[error]");
});

test("Run: the embedded stdlib resolves (sum -> 10)", async ({ page }) => {
  await editAndClick(page,
    'let l = require("std.list")\nprint(l.sum([1, 2, 3, 4]))', "#run");
  await expect(page.locator("#output")).toContainText("10");
});
```

- [ ] **Step 4: Create `tests/e2e/pages.spec.js`**

```js
const { test, expect } = require("@playwright/test");

test("landing page loads with nav links", async ({ page }) => {
  await page.goto("/index.html");
  await expect(page.locator("h1")).toContainText("Omelette");
  await expect(page.locator('a[href="guide.html"]').first()).toBeVisible();
  await expect(page.locator('a[href="play.html"]').first()).toBeVisible();
});

test("guide renders from docs/guide.md via marked", async ({ page }) => {
  await page.goto("/guide.html");
  // marked turns the markdown into headings; wait for one inside #guide
  await expect(page.locator("#guide h1, #guide h2").first()).toBeVisible({ timeout: 20000 });
  // the loading placeholder is gone, real markup is present
  await expect(page.locator("#guide")).not.toContainText("Loading the guide");
});
```

- [ ] **Step 5: Ignore the e2e install/report artifacts**

Append to `.gitignore`:
```
tests/e2e/node_modules/
tests/e2e/playwright-report/
tests/e2e/test-results/
```

- [ ] **Step 6: Generate the lockfile and validate locally (no browser)**

Generate a committed lockfile for reproducible CI installs (this fetches only the npm package, NOT a browser):
```bash
cd tests/e2e && npm install --package-lock-only
```
This writes `tests/e2e/package-lock.json` (commit it) without installing node_modules or a browser.

Then validate everything checkable without a browser:
```bash
# JS syntax of the specs + config
for f in tests/e2e/*.js; do node --check "$f" && echo "ok $f"; done
# the site builds and the selectors the tests use exist in the built HTML
lua site/build.lua
grep -q 'id="editor"' site/dist/play.html && grep -q 'id="output"' site/dist/play.html \
  && grep -q 'id="run"' site/dist/play.html && grep -q 'id="lua"' site/dist/play.html \
  && grep -q 'id="check"' site/dist/play.html && echo "play selectors OK"
grep -q 'id="guide"' site/dist/guide.html && echo "guide selector OK"
```
Expected: every `node --check` prints `ok`; `play selectors OK` and `guide selector OK` print. If a selector is missing, the test IDs and the built HTML have diverged — fix the spec to match the real HTML (do not change the site here).

- [ ] **Step 7: Commit**

```bash
git add tests/e2e/package.json tests/e2e/package-lock.json tests/e2e/playwright.config.js \
  tests/e2e/playground.spec.js tests/e2e/pages.spec.js .gitignore
git commit -m "test: Playwright playground e2e project (chromium, CI-only)"
```

---

### Task 2: The CI workflow (`.github/workflows/e2e.yml`)

**Files:**
- Create: `.github/workflows/e2e.yml`

**Interfaces:**
- Consumes: `tests/e2e/` (Task 1) + `lua site/build.lua`. Produces: an `e2e` CI job (the real verifier).

- [ ] **Step 1: Create `.github/workflows/e2e.yml`**

```yaml
name: e2e
# Runs ONLY in the ephemeral GitHub Actions runner (nothing on a dev machine, nothing published).
# Path-filtered to what the playground bundles, so it fires when any of that changes.
on:
  push:
    paths:
      - "site/**"
      - "tests/e2e/**"
      - "omelette/**"
      - "std/**"
      - "docs/guide.md"
      - ".github/workflows/e2e.yml"
  pull_request:
    paths:
      - "site/**"
      - "tests/e2e/**"
      - "omelette/**"
      - "std/**"
      - "docs/guide.md"
      - ".github/workflows/e2e.yml"
permissions:
  contents: read
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: leafo/gh-actions-lua@v13
        with:
          luaVersion: "luajit"
      - name: Build the site
        run: lua site/build.lua
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
      - name: Install e2e dependencies
        working-directory: tests/e2e
        run: npm ci
      - name: Install Chromium
        working-directory: tests/e2e
        run: npx playwright install --with-deps chromium
      - name: Run e2e tests
        working-directory: tests/e2e
        run: npx playwright test
      - name: Upload report on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: playwright-report
          path: tests/e2e/playwright-report/
          retention-days: 7
```

- [ ] **Step 2: Validate the workflow locally (structure only)**

```bash
# YAML is well-formed and has the expected shape (no local CI runner available)
lua -e 'print("(YAML validated by CI on push)")'   # placeholder — real check below
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/e2e.yml')); print('e2e.yml: valid YAML')"
grep -q "workflow_dispatch" .github/workflows/e2e.yml && echo "WARN unexpected" || echo "runs on push/pr (path-filtered)"
grep -q "deploy" .github/workflows/e2e.yml && echo "WARN deploy present" || echo "no deploy step (nothing publishes)"
grep -q "npx playwright test" .github/workflows/e2e.yml && echo "runs playwright"
```
Expected: `e2e.yml: valid YAML`, `no deploy step`, `runs playwright`. (The existing Lua test suite `luajit spec/run.lua` still passes — this cycle adds no Lua code.)

- [ ] **Step 3: Commit and push (CI is the real verifier)**

```bash
git add .github/workflows/e2e.yml
git commit -m "ci: run playground e2e (Playwright/Chromium) in a disposable runner"
```
After the branch is pushed / the PR opened, the **`e2e` job on GitHub is the acceptance signal** — it builds the site, installs Chromium in the runner, and runs the tests in a real browser. A green `e2e` check means the playground works end-to-end. If it fails, download the `playwright-report` artifact, fix the spec (selectors/expected text) or the site as needed, and push again.

---

## Self-Review

**1. Spec coverage:**
- CI-only Playwright, Chromium, isolated `tests/e2e/` npm → Tasks 1 + 2. ✓
- Cases (loads/Run=27/Compiled-Lua/Check-clean/type-mismatch/non-exhaustive/runtime-error/stdlib=10; landing; guide renders) → Task 1 spec files. ✓
- webServer serves lua-built `site/dist` via python3 → Task 1 config. ✓
- e2e.yml: push/PR path-filtered, builds site, installs chromium, runs tests, no deploy → Task 2. ✓
- Isolation / npm-free product; node_modules ignored; lockfile committed → Task 1 (.gitignore + package-lock). ✓
- Honest verification model (local checks + CI as verifier) → header + Task steps. ✓
- Deferred (local Docker run, other browsers, required-check) → not implemented (correct). ✓

No gaps.

**2. Placeholder scan:** The `lua -e 'print("(YAML validated by CI on push)")'` line in Task 2 Step 2 is a labeled placeholder line immediately followed by the REAL check (`python3 -c "import yaml..."`); it is illustrative, not a required step — the real validation is the `python3` YAML parse. All other steps have complete, runnable content (full package.json, config, both spec files, the workflow). No "TBD"/"implement later".

**3. Type consistency:** The selectors used in `playground.spec.js`/`pages.spec.js` (`#editor`, `#output`, `#run`, `#lua`, `#check`, `#guide`) match `site/src/play.html`/`guide.html` (Task 1 Step 6 greps the built HTML to confirm). The expected strings (`27`, `local M`, `No type errors`, `number`, `missing`, `[error]`, `10`, `Omelette`) match the compiler behavior verified via the playground's Lua drivers. `webServer` serves `../../site/dist` (relative to `tests/e2e/`), which the e2e.yml lua step builds. `npm ci` consumes the `package-lock.json` generated in Task 1 Step 6. ✓
