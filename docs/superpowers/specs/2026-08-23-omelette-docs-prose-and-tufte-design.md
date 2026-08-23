# Omelette — Docs Prose Rewrite + Tufte/OKLCH Styling Design

**Date:** 2026-08-23
**Status:** Approved design, pre-implementation
**Depends on:** the site + runnable docs (merged); supersedes the deferred "iambic-pentameter prose rewrite" gate

## Summary

Make the README, `docs/guide.md`, and site copy **terse, plain, and free of LLMisms**, and give
the site a **Tufte-style** design (vendored `tufte.css` + ET Book fonts) with a small
**OKLCH** color-token overlay. This is the pre-public polish; nothing publishes. The guide's
**CI-verified `egg`/`output`/`error` blocks are untouched** — only surrounding prose changes.

## Goals

- Every user-facing surface reads in the fewest correct words, with a deliberate but quiet meter.
- The site uses tufte.css typography + a perceptually-uniform OKLCH accent palette.
- The 18 verified guide examples stay byte-identical; `luajit spec/run.lua` and the Playwright e2e stay green.

## Non-Goals (deferred)

- **Dark mode** (tufte.css is fundamentally light/cream).
- Rewriting internal `docs/superpowers/**` specs/plans (not user-facing).
- Publishing (still gated on owner review + enabling Pages).
- An Omelette syntax highlighter for code blocks.

## Prose Style Guide (the writing contract)

**Terseness governs.** Meter and everything else bend to it.

- **Cut:** throat-clearing ("In this section…", "Let's…"), hedging ("it's worth noting", "arguably",
  "generally"), meta ("As you can see", "Note that"), and filler adverbs ("simply", "just",
  "effortlessly", "basically").
- **Prefer:** verbs over nominalizations; concrete over abstract; the shortest correct phrasing.
  Let code examples carry weight — describe what prose must, not what the example already shows.
- **No LLMisms (blocklist):** delve, seamless(ly), robust, leverage, elevate, unleash, realm,
  tapestry, testament, "in today's …", furthermore/moreover-as-filler, "not only … but also",
  empty rule-of-three lists, "dive in", "game-changer", "powerful and flexible", "designed to",
  "boasts", forced enthusiasm, and em-dash pileups. Prefer a period to an em-dash.
- **Meter:** lines carry an intentional, mixed cadence — loosely iambic, common meter, or
  pentameter, with deliberate deviations — **subordinate to terseness**. **No rhyme.** **No overt
  reference** to the meter. It must read as clean prose that happens to have a pulse; a reader
  should never think "this is verse".
- **Voice:** plain, direct, concrete, unhurried-but-brief. Second person for instructions.

Acceptance for prose is editorial (owner review), not automated — the only automated guard is that
the verified examples still pass.

## Surfaces

- **`README.md`** — what Omelette is, one example, how to build/run/check/test, where the guide is.
- **`docs/guide.md`** — rewrite the **prose** of all 11 sections; keep every ` ```egg `,
  ` ```output `, and ` ```error ` block **exactly** as-is (they are CI-verified; changing them
  breaks the suite). Prose may shrink; examples may not move in a way that breaks pairing
  (an `output`/`error` fence must stay immediately after its `egg` fence).
- **Site copy** — `site/src/index.html` (hero + bullets), `site/src/guide.html` (intro/loading
  text), `site/src/play.html` (the playground blurb).

## Styling — tufte.css + OKLCH

- **Vendor** into `site/vendor/`:
  - `tufte.css` (from edwardtufte/tufte-css, MIT).
  - `et-book/**` — the ET Book font files tufte.css references (roman, italic, bold, display;
    `.woff` + `.ttf`), preserving the `et-book/<face>/<file>` paths tufte.css uses.
- **Overlay** `site/src/site.css` (linked AFTER tufte.css so it wins):
  - **OKLCH tokens** in `:root`: `--ink`, `--bg` (tufte cream), `--accent`, `--accent-strong`,
    `--muted`, `--code-bg` — the accent hue defined once in `oklch(L C H)`, with tints/shades as
    uniform L/C steps. Links, the brand, and buttons use these tokens.
  - **Playground + chrome** (not covered by tufte.css): `#editor`, `#output`, `.controls button`,
    the header nav (`header`, `.brand`), and `a.button`.
  - Minimal tufte overrides needed for a docs/app hybrid (e.g. keep the header full-width; ensure
    the playground panes use a readable measure).
- **HTML:** wrap each page's content in `<article>` (tufte's expected container); keep the existing
  `#editor`/`#output`/`#run`/`#lua`/`#check` ids (the e2e depends on them) and `#guide`. Each page
  links `tufte.css` then `site.css`. The old `site/src/style.css` is removed (its rules move into
  `site.css` or are superseded by tufte.css).
- **Build (`site/build.lua`):** copy `tufte.css`, `et-book/**`, and `site.css` into `dist/`;
  drop `style.css`. The `site_build_spec` file list updates accordingly.

## Testing Strategy

Run under `luajit` (`luajit spec/run.lua`), existing harness; the Playwright e2e runs in CI.

- **Examples intact:** `spec/doc_guide_spec.lua` (all 18 blocks) stays green after the guide prose
  rewrite — this is the guard that the verified code/output/error blocks were not altered.
- **Build:** `spec/site_build_spec.lua` updated to assert the new dist file set (`tufte.css`,
  `site.css`, an `et-book/` font, no `style.css`) and that pages link `tufte.css` + `site.css`.
- **e2e stays green:** the playground selectors/behavior are unchanged; add one assertion (in
  `pages.spec.js`) that a page's computed font-family reflects tufte/ET Book (proving the vendored
  CSS loaded). CI is the verifier for the browser side.
- **Editorial review (owner):** prose quality (terseness, meter, no LLMisms) and the visual result,
  via `lua site/build.lua --serve`.
- **No regression:** the full Lua suite stays green; no compiler/language change.

## File Touchpoints

- Modify: `README.md`, `docs/guide.md` (prose only), `site/src/index.html`, `site/src/guide.html`,
  `site/src/play.html`, `site/build.lua`, `spec/site_build_spec.lua`, `tests/e2e/pages.spec.js`.
- Create: `site/src/site.css`, `site/vendor/tufte.css`, `site/vendor/et-book/**`.
- Remove: `site/src/style.css`.

No changes to the compiler, lexer, parser, codegen, typecheck, or the language.

## Deferred (record in `docs/DEFERRED.md`)

- Dark mode over tufte; an Omelette code highlighter; a fuller visual identity (logo, favicon).
- Publishing remains gated on owner review + enabling Pages (public repo or paid plan).
