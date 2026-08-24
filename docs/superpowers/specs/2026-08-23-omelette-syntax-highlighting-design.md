# Omelette — Syntax Highlighting (Site + Playground) Design

**Date:** 2026-08-23
**Status:** Approved design, pre-implementation
**Depends on:** the static site + guide + playground (merged)

## Summary

Add Omelette syntax highlighting to the site: the guide's ` ```egg ` blocks and the landing
hero (via **Prism** + a custom Omelette grammar + an OKLCH-token theme), and the **playground
editor** (via **code-input**, which overlays the *same* Prism grammar on the existing
`<textarea>`, so it highlights as you type while keeping a real textarea underneath). One
grammar, no build step, all vendored single files. Editor grammars (tree-sitter/TextMate) stay
deferred.

## Goals

- Guide `egg` code blocks and the landing hero are syntax-highlighted.
- The playground editor highlights as you type, and the underlying `<textarea>` (its `.value`)
  is preserved, so `play.js` and the e2e keep working.
- One Omelette grammar drives all of it; the theme uses the site's OKLCH tokens.
- `output`/`error` guide blocks stay plain (not Omelette code).

## Non-Goals (deferred)

- **Editor grammars** (tree-sitter / TextMate) for VS Code / Neovim — pairs with the deferred LSP.
- Full editor features (line numbers, bracket matching, autocomplete) — code-input is highlight-only.
- Highlighting the generated-Lua "Compiled Lua" output pane.

## Decisions

| Decision | Choice |
|---|---|
| Site highlighter | **Prism** (core + custom `omelette` grammar), aliased to `egg` |
| Playground editor | **code-input** web component overlaying Prism on the `<textarea>` |
| Grammar | one `prism-omelette.js`, matching the lexer; `egg` = alias of `omelette` |
| Theme | OKLCH tokens (in `site.css` / a small theme block), consistent with tufte palette |
| Vendored | `prism.js` (core), `code-input.min.js` + `code-input.min.css` — single files |

## The Omelette Prism grammar (`site/vendor` + `site/src/prism-omelette.js`)

Defines `Prism.languages.omelette` and aliases `Prism.languages.egg = Prism.languages.omelette`.
Token classes (matching `omelette/lexer.lua`):
- `comment`: `--` to end of line.
- `string`: `"…"` with escapes.
- `keyword`: `let pub fn if then else match with when type and or not lua to`.
- `boolean`/`constant`: `true false nil`.
- `class-name` (constructors): a Capitalized identifier `\b[A-Z]\w*` (the capitalization rule).
- `number`: integer/decimal.
- `operator`: `|> -> => <- .. == ~= <= >= < > = + - * / % # : |`.
- `punctuation`: `{ } [ ] ( ) , .`.

Order matters (comments/strings before operators). The grammar is authored to mirror the lexer;
a tiny divergence only affects colors, never correctness.

## Theme (OKLCH)

Small rules (in `site.css`), perceptually-tuned hues off the existing tokens:
- `.token.comment` → `var(--muted)`, italic.
- `.token.keyword` → `var(--accent-strong)`, semibold.
- `.token.string` → a green `oklch(…)`.
- `.token.class-name` (constructors) → a purple `oklch(…)`.
- `.token.number` → a warm `oklch(…)`.
- `.token.boolean`, `.token.operator`, `.token.punctuation` → ink/muted.
Light + dark handled by the existing `--` token overrides.

## Integration

**Guide (`guide.html`):** after `marked.parse` sets `#guide`, call
`Prism.highlightAllUnder(document.getElementById("guide"))`. marked emits
`<code class="language-egg">`, which the grammar (aliased) highlights; `language-output` /
`language-error` are unregistered → left plain.

**Landing (`index.html`):** the hero `<pre><code>` gets `class="language-egg"`; Prism highlights
on load. Include `prism.js` + `prism-omelette.js`.

**Playground (`play.html` + `play.js`):**
- Replace `<textarea id="editor">…</textarea>` with
  `<code-input id="editor" language="omelette" template="omelette">…</code-input>` (seed text
  as its content). Register the template once:
  `codeInput.registerTemplate("omelette", codeInput.templates.prism(Prism));`
- `play.js` reads `document.getElementById("editor").value` (code-input exposes `.value`) — the
  existing `drive()`/`__src` flow is unchanged.
- Include order: `prism.js`, `prism-omelette.js`, `code-input.min.js`, then `play.js`.

**Build (`site/build.lua`):** copy `prism.js`, `prism-omelette.js`, `code-input.min.js`,
`code-input.min.css` into `dist/` (the theme lives in `site.css`, already copied). Update
`site_build_spec` to assert the new files + that `play.html` references code-input.

## Testing Strategy

- **Lua suite** (`luajit spec/run.lua`): `site_build_spec` updated for the new dist assets and
  the play.html references; all prior green. (No compiler/language change.)
- **e2e** (CI): the playground editor is still a `<textarea>` under code-input, so the existing
  cases keep working — but selectors adjust: set content via the inner textarea
  (`#editor textarea`) instead of `#editor` directly, and read `.value` as before. Add one
  assertion that highlighting is active: after loading `/play.html`, a `#editor .token` span
  exists (the code-input overlay produced tokens). Guide highlighting: assert a `.token` appears
  inside `#guide` after render.
- **Editorial/visual (owner):** the actual colors + readability via `--serve`.

## File Touchpoints

- Create: `site/src/prism-omelette.js`; `site/vendor/prism.js`, `site/vendor/code-input.min.js`,
  `site/vendor/code-input.min.css`.
- Modify: `site/src/index.html`, `site/src/guide.html`, `site/src/play.html`, `site/src/play.js`,
  `site/src/site.css` (theme), `site/build.lua`, `spec/site_build_spec.lua`,
  `tests/e2e/playground.spec.js`, `tests/e2e/pages.spec.js`.

No changes to the compiler, lexer, parser, codegen, or typecheck.

## Deferred (record in `docs/DEFERRED.md`)

- Editor grammars (tree-sitter / TextMate) for VS Code / Neovim (with the LSP).
- Highlighting the "Compiled Lua" output as Lua; richer editor features.
