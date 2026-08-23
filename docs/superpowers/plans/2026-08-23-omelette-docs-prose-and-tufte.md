# Omelette Docs Prose + Tufte/OKLCH Styling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Terse, LLMism-free, subtly-metered prose across README + guide + site, and a Tufte-styled site (vendored `tufte.css` + ET Book fonts) with an OKLCH color-token overlay — with the guide's CI-verified examples untouched.

**Architecture:** Task 1 vendors `tufte.css` + the ET Book fonts, adds an `site/src/site.css` OKLCH overlay, restructures the three pages to Tufte's `<article>` container, and updates the build + tests. Task 2 rewrites the prose of README, `docs/guide.md` (fenced example blocks byte-identical), and the site copy to the style contract. No compiler/language change.

**Tech Stack:** Static site (no framework); vendored single-file CSS + fonts; the existing Lua build + Playwright e2e.

## Global Constraints

- **The guide's 18 ` ```egg ` / ` ```output ` / ` ```error ` blocks stay BYTE-IDENTICAL** (they are CI-verified by `spec/doc_guide_spec.lua`; an `output`/`error` fence must remain immediately after its `egg` fence). Only prose changes.
- **Prose style contract** (from the spec): terseness governs; no LLMisms (blocklist below); mixed intentional meter (iambic / common meter / pentameter + deviations), **no rhyme, never announced**; plain, concrete, verb-forward. Acceptance is editorial (owner review); the only automated guard is that the verified examples still pass.
- **Blocklist:** delve, seamless(ly), robust, leverage, elevate, unleash, realm, tapestry, testament, "in today's …", furthermore/moreover-as-filler, "not only…but also", empty rule-of-three, "dive in", "game-changer", "powerful and flexible", "designed to", "boasts", forced enthusiasm, em-dash pileups.
- Keep the playground ids (`#editor`/`#output`/`#run`/`#lua`/`#check`) and `#guide` (the e2e depends on them). Nothing publishes.

---

### Task 1: Tufte + OKLCH styling

**Files:**
- Create: `site/vendor/tufte.css`, `site/vendor/et-book/**` (16 font files), `site/src/site.css`
- Modify: `site/src/index.html`, `site/src/guide.html`, `site/src/play.html`, `site/build.lua`, `spec/site_build_spec.lua`, `tests/e2e/pages.spec.js`
- Remove: `site/src/style.css`

**Interfaces:**
- Produces: a Tufte-styled `dist/` (`tufte.css` + `et-book/**` + `site.css`, no `style.css`); pages link `tufte.css` then `site.css`.

- [ ] **Step 1: Vendor tufte.css + the ET Book fonts**

```bash
cd site
B=https://raw.githubusercontent.com/edwardtufte/tufte-css/gh-pages
curl -fsSL "$B/tufte.css" -o vendor/tufte.css
for face in et-book-bold-line-figures et-book-display-italic-old-style-figures \
            et-book-roman-line-figures et-book-roman-old-style-figures; do
  mkdir -p "vendor/et-book/$face"
  for ext in eot svg ttf woff; do
    curl -fsSL "$B/et-book/$face/$face.$ext" -o "vendor/et-book/$face/$face.$ext"
  done
done
test -s vendor/tufte.css && ls vendor/et-book/*/*.woff | wc -l   # expect 4 woff + others
cd ..
```
(If the environment has no network, STOP and report NEEDS_CONTEXT — the main agent will vendor these.)

- [ ] **Step 2: Write the OKLCH overlay `site/src/site.css`**

Loaded after `tufte.css`, so it wins. Tufte handles body/measure/typography and its own dark-mode block; this adds a perceptually-uniform accent, the header nav, and the playground chrome.
```css
/* OKLCH color tokens — one accent hue, tints as uniform lightness steps.
   Light defaults; a dark override mirrors tufte.css's prefers-color-scheme block. */
:root {
  --accent:        oklch(0.55 0.15 35);
  --accent-strong: oklch(0.45 0.16 35);
  --muted:         oklch(0.55 0.02 60);
  --rule:          oklch(0.88 0.01 60);
  --code-bg:       oklch(0.96 0.008 75);
}
@media (prefers-color-scheme: dark) {
  :root {
    --accent:        oklch(0.75 0.14 45);
    --accent-strong: oklch(0.82 0.13 45);
    --muted:         oklch(0.72 0.02 60);
    --rule:          oklch(0.32 0.01 60);
    --code-bg:       oklch(0.26 0.01 75);
  }
}

/* links + brand use the accent */
a { color: var(--accent); }
a:hover { color: var(--accent-strong); }

/* full-width header nav (tufte leaves this to us) */
header {
  display: flex; gap: 1.4rem; align-items: baseline;
  padding: 1rem 5%; border-bottom: 1px solid var(--rule); margin-bottom: 2rem;
}
header .brand { font-weight: 700; color: var(--accent); }
header a { text-decoration: none; }

/* buttons */
a.button, .controls button {
  font: inherit; cursor: pointer; border-radius: 4px;
  border: 1px solid var(--accent); color: var(--accent); background: transparent;
  padding: 0.4rem 0.9rem; margin: 0.3rem 0.4rem 0.3rem 0; text-decoration: none;
  display: inline-block;
}
a.button:hover, .controls button:hover { background: var(--accent); color: #fffff8; }

/* playground panes (not part of tufte) */
#editor, #output {
  width: 100%; font-family: Consolas, "Liberation Mono", Menlo, monospace; font-size: 0.85rem;
}
#editor { height: 18rem; padding: 0.7rem; border: 1px solid var(--rule); border-radius: 4px; }
#output {
  white-space: pre-wrap; background: var(--code-bg); color: inherit;
  padding: 0.7rem; border-radius: 4px; min-height: 6rem; margin-top: 0.6rem;
}

/* keep code blocks legible on the cream background */
pre > code, code { background: var(--code-bg); }
```

- [ ] **Step 3: Restructure the three pages (link tufte + site.css; wrap in `<article>`)**

For each of `index.html`, `guide.html`, `play.html`:
- In `<head>`, replace `<link rel="stylesheet" href="style.css">` with:
  ```html
  <link rel="stylesheet" href="tufte.css">
  <link rel="stylesheet" href="site.css">
  ```
- Wrap the page's main content (everything after `<header>…</header>`) in `<article>…</article>`
  (Tufte's expected container). Keep the `<header>` nav as-is (styled by `site.css`).
- Keep all existing ids (`#editor`, `#output`, `#run`, `#lua`, `#check`, `#guide`) and the
  `<script>` tags exactly. `guide.html` keeps `<article id="guide">…</article>`.

(Exact prose inside these pages is rewritten in Task 2; Task 1 only changes structure + links.)

- [ ] **Step 4: Update the build to ship the new assets**

In `site/build.lua`'s `M.build()`:
- Replace `"style.css"` in the `site/src/*` copy list with `"site.css"`.
- Copy `tufte.css` from vendor, and recursively copy `site/vendor/et-book/` into `site/dist/et-book/`.
  Add helpers/loop:
  ```lua
  -- vendored css + fonts
  for _, f in ipairs({ "fengari-web.js", "marked.min.js", "tufte.css" }) do
    copy("site/vendor/" .. f, "site/dist/" .. f)
  end
  -- et-book fonts (recursive copy via shell; portable enough for the build)
  os.execute("mkdir -p site/dist/et-book && cp -R site/vendor/et-book/. site/dist/et-book/")
  ```
  (And `"site.css"` is copied by the `site/src/*` loop.)

- [ ] **Step 5: Update `spec/site_build_spec.lua`**

Change the expected-files list: replace `site/dist/style.css` with `site/dist/site.css`, add
`site/dist/tufte.css` and one font, e.g. `site/dist/et-book/et-book-roman-line-figures/et-book-roman-line-figures.woff`. Update the play.html assertion to check it links `tufte.css` and `site.css`:
```lua
    local html = slurp("site/dist/play.html")
    h.truthy(html:find("tufte%.css"))
    h.truthy(html:find("site%.css"))
    h.truthy(slurp("site/dist/play.js"):find('fetch%("omelette%-browser%.lua"'))
```

- [ ] **Step 6: Add an e2e assertion that tufte loaded**

In `tests/e2e/pages.spec.js`, add to the landing test (or a new test) an assertion that the ET Book
font is in effect (proves `tufte.css` + fonts loaded):
```js
test("tufte styling is applied", async ({ page }) => {
  await page.goto("/index.html");
  const family = await page.evaluate(() => getComputedStyle(document.body).fontFamily);
  expect(family.toLowerCase()).toContain("et-book");
});
```

- [ ] **Step 7: Build, run the Lua suite, self-review**

Run: `luajit spec/run.lua` → `site_build_spec` green (new file set) and all prior green.
Run: `lua site/build.lua` → confirm `site/dist/` has `tufte.css`, `site.css`, `et-book/…/*.woff`,
no `style.css`. (The visual result + the e2e font assertion are verified in CI / owner review.)

- [ ] **Step 8: Commit**

```bash
git add site/vendor/tufte.css site/vendor/et-book site/src/site.css \
  site/src/index.html site/src/guide.html site/src/play.html site/build.lua \
  spec/site_build_spec.lua tests/e2e/pages.spec.js
git rm site/src/style.css
git commit -m "feat(site): Tufte styling (vendored tufte.css + ET Book) + OKLCH token overlay"
```

---

### Task 2: Prose rewrite (README, guide, site copy)

**Files:**
- Modify: `README.md`, `docs/guide.md` (prose only), `site/src/index.html`, `site/src/guide.html`, `site/src/play.html`

**Interfaces:**
- Consumes: the style contract (Global Constraints). Produces: rewritten prose; the verified guide blocks unchanged.

- [ ] **Step 1: Rewrite `README.md`**

Apply the style contract. Cover, in the fewest correct words: what Omelette is (an ML that
compiles to readable Lua 5.1); one short example; the commands (`omelette run/build/check`,
`luajit spec/run.lua`); where the guide is. No LLMisms; quiet meter; no meta.

*Style demonstration (apply this feel throughout):*
- Before: "Omelette is a small, immutable, ML-flavored language that is designed to compile to
  clean and readable Lua 5.1, making it a powerful and flexible choice for scripting."
- After: "Omelette is a small ML that compiles to plain Lua 5.1. Values are immutable; the output
  reads like hand-written Lua."

- [ ] **Step 2: Rewrite the prose of `docs/guide.md`**

For each of the 11 sections, tighten the surrounding prose to the style contract. **Do not touch any
` ```egg `, ` ```output `, or ` ```error ` block** — copy them through verbatim, and keep each
`output`/`error` fence immediately after its `egg` fence. Prose may shrink; a section may become a
sentence plus its example. Introduce each construct by what it *is* and what the example does not
already make obvious — never narrate the code line by line.

- [ ] **Step 3: Verify the examples are intact**

Run: `luajit spec/run.lua`
Expected: PASS — `spec/doc_guide_spec.lua` green (all 18 blocks still compile/run/error as before).
If any doc-guide test fails, a fenced block was altered — restore it byte-for-byte.

- [ ] **Step 4: Rewrite the site copy**

`site/src/index.html` (hero line + the feature bullets), `site/src/guide.html` (the "Loading…"
text and any intro), `site/src/play.html` (the one-line blurb). Same contract: terse, no LLMisms,
quiet meter. Keep all tags/ids/scripts; change only human-readable text.

- [ ] **Step 5: Build + final self-review**

Run: `luajit spec/run.lua` (green) and `lua site/build.lua` (site rebuilds). Read the rendered
site via `lua site/build.lua --serve` mentally / structurally; the meter+terseness+visual quality
is the owner's editorial review. Confirm no fenced example changed (diff `docs/guide.md` for
```-fenced regions).

- [ ] **Step 6: Commit**

```bash
git add README.md docs/guide.md site/src/index.html site/src/guide.html site/src/play.html
git commit -m "docs: terse, LLMism-free prose across README, guide, and site copy"
```

---

## Self-Review

**1. Spec coverage:**
- Vendor tufte.css + ET Book fonts → Task 1 Step 1. ✓
- OKLCH token overlay (`site.css`), links/brand/buttons/playground chrome → Task 1 Step 2. ✓
- Pages link tufte + site.css, wrapped in `<article>`; ids preserved → Task 1 Step 3. ✓
- Build ships new assets, drops style.css; site_build_spec updated → Task 1 Steps 4–5. ✓
- e2e proves tufte loaded → Task 1 Step 6. ✓
- Prose rewrite of README + guide + site to the contract, LLMism blocklist → Task 2. ✓
- Guide's verified blocks byte-identical (doctest green) → Global Constraint + Task 2 Steps 2–3. ✓
- Editorial acceptance = owner review; automated guard = examples pass → header + steps. ✓
- Deferred (dark mode note, highlighter, publishing) → not implemented (correct). ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". The vendoring commands, the full `site.css`, the build/spec
edits, and the e2e assertion are concrete. Task 2's deliverable is *edited prose*, which is inherently
authored at execution — the plan pins the contract, the blocklist, a worked before/after example, and
the hard constraint (fenced blocks untouched, doctest green) so the result is consistent and checkable.

**3. Type consistency:** The build copies `site.css` (not `style.css`); `site_build_spec` asserts the
same new file set; the pages link `tufte.css` + `site.css`; the e2e checks `et-book` in the computed
font-family, which the vendored fonts + tufte.css provide. The playground ids and `#guide` are
unchanged, so the existing e2e selectors still resolve. ✓
