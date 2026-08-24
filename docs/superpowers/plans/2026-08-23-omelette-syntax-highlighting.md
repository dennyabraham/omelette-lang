# Omelette Syntax Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **VERIFICATION NOTE:** the in-browser highlighting can't be verified in the authoring environment (no browser). Locally verify the buildable/testable parts (grammar is valid JS via `node --check`, the site builds, `site_build_spec` green); the **e2e job on CI** verifies the tokens actually render, and the colors are the owner's visual review.

**Goal:** Syntax-highlight the guide's `egg` blocks + the landing hero (Prism + a custom Omelette grammar + OKLCH theme), and the playground editor (code-input overlaying the same grammar on the textarea).

**Architecture:** One Omelette Prism grammar drives both. Task 1: Prism + grammar + theme highlight the guide (client-side, after marked) and the hero. Task 2: code-input wraps the playground `<textarea>` with the same grammar (textarea + `.value` preserved, so `play.js` and the e2e keep working).

**Tech Stack:** Vendored single-file JS/CSS (Prism core, code-input); no build/framework.

## Global Constraints

- All vendored single files; no npm/bundler. One Omelette grammar (`prism-omelette.js`), aliased so `egg` = `omelette`.
- The playground editor stays a real `<textarea>` (under code-input), so `play.js` (`#editor.value`) and the e2e keep functioning.
- `output`/`error` guide blocks are unregistered languages → stay plain. No compiler/language change.
- Theme uses the site's OKLCH tokens (light + dark).

---

### Task 1: Prism grammar + guide/hero highlighting + theme

**Files:**
- Create: `site/vendor/prism.js` (Prism core — pre-vendored), `site/src/prism-omelette.js`
- Modify: `site/src/site.css` (token theme), `site/src/guide.html`, `site/src/index.html`, `site/build.lua`, `spec/site_build_spec.lua`, `tests/e2e/pages.spec.js`

**Interfaces:**
- Produces: `Prism.languages.omelette` (+ `egg` alias); highlighted `egg` blocks in the guide + hero.

- [ ] **Step 1: Vendor Prism core (pre-vendored by the main agent; verify present)**

`site/vendor/prism.js` should already exist. If not:
```bash
curl -fsSL https://cdn.jsdelivr.net/npm/prismjs@1.29.0/components/prism-core.min.js -o site/vendor/prism.js
test -s site/vendor/prism.js && echo "prism vendored"
```

- [ ] **Step 2: Write `site/src/prism-omelette.js` (the grammar)**

```js
// Omelette grammar for Prism — mirrors omelette/lexer.lua. Aliased to `egg`.
Prism.languages.omelette = {
  comment: /--.*/,
  string: { pattern: /"(?:\\.|[^"\\])*"/, greedy: true },
  keyword: /\b(?:let|pub|fn|if|then|else|match|with|when|type|and|or|not|lua|to)\b/,
  boolean: /\b(?:true|false|nil)\b/,
  "class-name": /\b[A-Z]\w*/, // capitalized identifier = constructor (Omelette convention)
  number: /\b\d+(?:\.\d+)?\b/,
  operator: /\|>|->|=>|<-|\.\.|==|~=|<=|>=|[-+*/%<>=|:#]/,
  punctuation: /[{}[\]().,]/,
};
Prism.languages.egg = Prism.languages.omelette;
```

- [ ] **Step 3: Add the OKLCH token theme to `site/src/site.css`**

Append:
```css
/* Prism token theme (OKLCH; matches the site palette, light + dark) */
.token.comment { color: var(--muted); font-style: italic; }
.token.keyword { color: var(--accent-strong); font-weight: 600; }
.token.string { color: oklch(0.52 0.12 150); }
.token.boolean, .token.number { color: oklch(0.55 0.14 45); }
.token.class-name { color: oklch(0.52 0.14 285); }
.token.operator, .token.punctuation { color: var(--muted); }
@media (prefers-color-scheme: dark) {
  .token.string { color: oklch(0.78 0.13 150); }
  .token.boolean, .token.number { color: oklch(0.8 0.12 45); }
  .token.class-name { color: oklch(0.8 0.12 285); }
}
```

- [ ] **Step 4: Wire the guide + hero**

`site/src/guide.html` — after the marked render, highlight; add the Prism scripts. Change the
script block to:
```html
<script src="marked.min.js"></script>
<script src="prism.js"></script>
<script src="prism-omelette.js"></script>
<script>
fetch("guide.md").then(function(r){return r.text();}).then(function(md){
  var el = document.getElementById("guide");
  el.innerHTML = marked.parse(md);
  Prism.highlightAllUnder(el);
}).catch(function(){
  document.getElementById("guide").textContent =
    "Could not load the guide — serve the site over http (run `lua site/build.lua --serve`); file:// won't work.";
});
</script>
```

`site/src/index.html` — give the hero code block the language class and load Prism. Change the
hero `<pre><code>` opening tag to `<pre><code class="language-egg">`, and before `</body>` add:
```html
<script src="prism.js"></script>
<script src="prism-omelette.js"></script>
```

- [ ] **Step 5: Build + `site_build_spec`**

`site/build.lua` `M.build()` — add `prism.js` to the vendored-copy loop and `prism-omelette.js`
to the `site/src/*` copy loop:
```lua
  for _, f in ipairs({ "index.html", "guide.html", "play.html", "site.css", "play.js", "prism-omelette.js" }) do
    copy("site/src/" .. f, "site/dist/" .. f)
  end
  for _, f in ipairs({ "fengari-web.js", "marked.min.js", "tufte.css", "prism.js" }) do
    copy("site/vendor/" .. f, "site/dist/" .. f)
  end
```
`spec/site_build_spec.lua` — add `"site/dist/prism.js"` and `"site/dist/prism-omelette.js"` to the
expected-files list, and assert the guide links Prism:
```lua
  h.it("guide.html highlights via Prism", function()
    site.build()
    local html = assert(io.open("site/dist/guide.html","r")):read("*a")
    h.truthy(html:find("prism%.js"))
    h.truthy(html:find("highlightAllUnder"))
  end)
```

- [ ] **Step 6: e2e — guide highlighting renders**

In `tests/e2e/pages.spec.js`, extend the guide test: after it renders, a Prism token span exists.
```js
  await expect(page.locator("#guide .token").first()).toBeVisible({ timeout: 20000 });
```

- [ ] **Step 7: Verify + commit**

`luajit spec/run.lua` (site_build_spec green); `node --check site/src/prism-omelette.js` (use
`/Users/dennyabraham/.asdf/installs/nodejs/19.0.0/bin/node` if the asdf shim errors); `lua
site/build.lua` produces `dist/prism.js` + `dist/prism-omelette.js`. Then:
```bash
git add site/vendor/prism.js site/src/prism-omelette.js site/src/site.css \
  site/src/guide.html site/src/index.html site/build.lua spec/site_build_spec.lua tests/e2e/pages.spec.js
git commit -m "feat(site): Prism syntax highlighting for the guide + hero"
```

---

### Task 2: code-input playground editor

**Files:**
- Create: `site/vendor/code-input.min.js`, `site/vendor/code-input.min.css` (pre-vendored)
- Modify: `site/src/play.html`, `site/build.lua`, `spec/site_build_spec.lua`, `tests/e2e/playground.spec.js`

**Interfaces:**
- Consumes: the Prism grammar (Task 1). Produces: a highlighting playground editor; `#editor.value` still readable by `play.js`.

- [ ] **Step 1: Vendor code-input (pre-vendored; verify present)**

`site/vendor/code-input.min.js` + `code-input.min.css` should already exist. If not:
```bash
curl -fsSL https://cdn.jsdelivr.net/npm/@webcoder49/code-input@2.4.0/code-input.min.js -o site/vendor/code-input.min.js
curl -fsSL https://cdn.jsdelivr.net/npm/@webcoder49/code-input@2.4.0/code-input.min.css -o site/vendor/code-input.min.css
test -s site/vendor/code-input.min.js && test -s site/vendor/code-input.min.css && echo "code-input vendored"
```

- [ ] **Step 2: Swap the textarea for code-input in `play.html`**

- In `<head>`, add `<link rel="stylesheet" href="code-input.min.css">` (after site.css).
- Replace the `<textarea id="editor" spellcheck="false">…seed…</textarea>` with:
  ```html
  <code-input id="editor" language="omelette" template="omelette">type Shape = | Circle { radius } | Origin

  let area s =
    match s with
    | Circle { radius } -> 3 * radius * radius
    | Origin            -> 0

  print(area(Circle { radius = 3 }))
  </code-input>
  ```
  (keep the exact seed text that was in the textarea).
- Before `play.js`, load Prism + grammar + code-input and register the template. Replace the
  script tail with:
  ```html
  <script src="fengari-web.js"></script>
  <script src="prism.js"></script>
  <script src="prism-omelette.js"></script>
  <script src="code-input.min.js"></script>
  <script>codeInput.registerTemplate("omelette", codeInput.templates.prism(Prism));</script>
  <script src="play.js"></script>
  ```
  (`play.js` is unchanged — `document.getElementById("editor").value` works: code-input exposes `.value`.)

- [ ] **Step 3: Build + `site_build_spec`**

`site/build.lua` — add code-input to the vendored-copy loop:
```lua
  for _, f in ipairs({ "fengari-web.js", "marked.min.js", "tufte.css", "prism.js",
                       "code-input.min.js", "code-input.min.css" }) do
    copy("site/vendor/" .. f, "site/dist/" .. f)
  end
```
`spec/site_build_spec.lua` — add `"site/dist/code-input.min.js"` + `"site/dist/code-input.min.css"`
to expected files; in the play.html assertion, add `h.truthy(html:find("code%-input"))`.

- [ ] **Step 4: Update the e2e for the code-input editor**

The editor is now `<code-input id="editor">` with an inner `<textarea>`. In
`tests/e2e/playground.spec.js`, set content via the inner textarea and assert highlighting:
- Replace `page.fill("#editor", src)` with `page.fill("#editor textarea", src)` in the helper.
- The seeded-example Run test types the seed itself (don't rely on default) via the helper.
- Add a highlighting assertion after load:
  ```js
  test("the editor highlights (a token span is present)", async ({ page }) => {
    await expect(page.locator("#editor .token").first()).toBeVisible({ timeout: 20000 });
  });
  ```
Reading output (`#output`) and the Run/Check flow are unchanged.

- [ ] **Step 5: Verify + commit**

`luajit spec/run.lua` green; `lua site/build.lua` produces the code-input files in `dist/`.
(The editor highlighting + the e2e token assertions are verified by CI; the look is the owner's
`--serve` review.)
```bash
git add site/vendor/code-input.min.js site/vendor/code-input.min.css site/src/play.html \
  site/build.lua spec/site_build_spec.lua tests/e2e/playground.spec.js
git commit -m "feat(site): highlight the playground editor via code-input + Prism"
```

---

## Self-Review

**1. Spec coverage:**
- Prism + Omelette grammar (aliased `egg`) + OKLCH theme → Task 1 Steps 2–3. ✓
- Guide `egg` blocks + hero highlighted → Task 1 Step 4. ✓
- Playground editor via code-input on the textarea; `.value` preserved → Task 2 Steps 1–2. ✓
- One grammar for both; vendored single files; no build → Tasks 1–2. ✓
- `output`/`error` blocks stay plain (unregistered) → inherent (grammar only registers omelette/egg). ✓
- Build ships new assets; `site_build_spec` updated → Task 1 Step 5, Task 2 Step 3. ✓
- e2e: guide token + editor token assertions; textarea still drivable → Task 1 Step 6, Task 2 Step 4. ✓
- Deferred (editor grammars, Lua-output highlighting) → not implemented (correct). ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". The grammar, theme, HTML edits, build/spec/e2e edits are given in full. The vendoring curl commands are exact (with a "pre-vendored; verify present" note). The only browser-verified pieces (do the tokens actually render / does code-input read back through Playwright) are explicitly CI-verified via the added `.token` assertions — not placeholders.

**3. Type consistency:** `prism-omelette.js` defines `Prism.languages.omelette`/`egg`, which the guide (marked's `language-egg`) and the hero (`class="language-egg"`) and code-input (`language="omelette"`) all reference. `play.js` still reads `#editor.value` (code-input exposes it). `site_build_spec` asserts exactly the files `M.build()` now copies. The e2e selectors (`#editor textarea`, `#output`, `.token`) match the built DOM. ✓
