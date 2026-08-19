# Omelette Static Website & Playground Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **PREREQUISITE:** PR #14 (runnable docs) must be merged into `canon` first — this cycle renders `docs/guide.md` and embeds the guide's stdlib. Rebase this branch onto the updated `canon` before starting.

**Goal:** A dependency-light static site (landing / guide / playground) reviewable locally; the playground runs the real compiler in-browser via Fengari with embedded stdlib. Nothing is published.

**Architecture:** Task 1 builds `site/build.lua`'s `build_bundle()` — a browser bundle (`package.preload` for the compiler incl. typecheck + embedded `std/*.egg` + a browser searcher, no CLI) — verified in a fresh Lua VM (a Fengari stand-in). Task 2 adds the pages, vendored libs, the full `build()` that assembles `site/dist/` (with `--serve`), a `workflow_dispatch`-only Pages workflow (Pages stays OFF), and a build-output test.

**Tech Stack:** Pure Lua build; hand-written HTML/CSS/JS; vendored `fengari-web.js` + `marked.js`; GitHub Pages (unpublished).

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline**. Test runner is `luajit spec/run.lua`.
- **No npm / framework / SSG.** Build is one Lua script; JS libs are vendored single files.
- The browser bundle: `package.preload` for `lexer, errors, resolver, parser, codegen, typecheck, compiler`; embeds `std/*.egg` + a browser searcher; **no `cli.main` auto-run**.
- The playground is **100% client-side** (Fengari). The guide on the site IS `docs/guide.md` (rendered client-side by `marked.js`).
- **Nothing is published.** The Pages workflow is `workflow_dispatch`-only and Pages stays disabled. Publishing is gated on owner review + the (deferred) iambic-pentameter rewrite.
- `site/dist/` is the build artifact (already git-ignored by the existing `dist/` rule).

---

### Task 1: The browser bundle (`build_bundle`) + fresh-VM test

**Files:**
- Create: `site/build.lua` (with the `build_bundle()` function; `build()` filesystem assembly is Task 2)
- Create: `spec/browser_bundle_spec.lua`

**Interfaces:**
- Produces: `require("site.build").build_bundle() -> <string>` — a self-contained Lua bundle that, when run in a fresh Lua VM, makes `require("omelette.compiler")` and `require("std.*")` work with no filesystem.

- [ ] **Step 1: Write the failing test**

`spec/browser_bundle_spec.lua`:
```lua
local h = require("spec.support.harness")
local site = require("site.build")

-- run a driver in a FRESH luajit (no ./ on package.path), so require resolves
-- ONLY through the bundle's package.preload + embedded-std searcher — the same
-- isolation Fengari has in the browser.
local function run_fresh(bundle, driver_body)
  local tmpb, tmpd = os.tmpname(), os.tmpname() .. ".lua"
  local fb = io.open(tmpb, "w"); fb:write(bundle); fb:close()
  local fd = io.open(tmpd, "w"); fd:write('dofile("' .. tmpb .. '")\n' .. driver_body); fd:close()
  local p = io.popen('luajit "' .. tmpd .. '" 2>&1')
  local out = p:read("*a"); p:close()
  os.remove(tmpb); os.remove(tmpd)
  return out
end

h.describe("browser bundle", function()
  local bundle = site.build_bundle()

  h.it("preloads the compiler and runs code with no filesystem", function()
    local out = run_fresh(bundle, 'require("omelette.compiler").eval("print(1 + 2)")')
    h.truthy(out:find("3"))
  end)
  h.it("resolves the embedded stdlib via require (no ./std on disk)", function()
    local out = run_fresh(bundle,
      'require("omelette.compiler").eval([==[let l = require("std.list") print(l.sum([1, 2, 3]))]==])')
    h.truthy(out:find("6"))
  end)
  h.it("bundles typecheck so check() works", function()
    local out = run_fresh(bundle,
      'local d = require("omelette.compiler").check([==[let x: number = "hi"]==]); print(#d)')
    h.truthy(out:find("1"))
  end)
  h.it("does not auto-run the CLI", function()
    h.truthy(not bundle:find("cli"))
    h.truthy(not bundle:find("%.main%("))
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `module 'site.build' not found`.

- [ ] **Step 3: Implement `site/build.lua` (`build_bundle` only)**

```lua
-- Builds the Omelette website into site/dist/. `build_bundle()` produces the
-- browser compiler bundle (loaded into Fengari); `build()` (Task 2) assembles dist/.
local M = {}

-- compiler modules the browser needs (NB: typecheck is included — it is missing
-- from build/amalgamate.lua; the searcher/repl/cli are NOT needed in the browser)
local BUNDLE_MODULES = { "lexer", "errors", "resolver", "parser", "codegen", "typecheck", "compiler" }
local STD_MODULES = { "list", "string", "table" }

local function read(path)
  local fh = assert(io.open(path, "r"), "cannot read " .. path)
  local s = fh:read("*a"); fh:close(); return s
end

-- long-bracket level that does not collide with the source
local function longstring(s)
  local eq = "="
  while s:find("]" .. eq .. "]", 1, true) do eq = eq .. "=" end
  return "[" .. eq .. "[\n" .. s .. "]" .. eq .. "]"
end

function M.build_bundle()
  local parts = {}
  -- 1) preload every compiler module
  for _, name in ipairs(BUNDLE_MODULES) do
    parts[#parts + 1] = 'package.preload["omelette.' .. name .. '"] = function(...)'
    parts[#parts + 1] = read("omelette/" .. name .. ".lua")
    parts[#parts + 1] = "end"
  end
  -- 2) embed the stdlib sources
  parts[#parts + 1] = "local __omelette_std = {}"
  for _, name in ipairs(STD_MODULES) do
    parts[#parts + 1] = '__omelette_std["std.' .. name .. '"] = ' .. longstring(read("std/" .. name .. ".egg"))
  end
  -- 3) a browser searcher: compile embedded .egg sources on require (no filesystem)
  parts[#parts + 1] = [[
local __searchers = package.searchers or package.loaders
table.insert(__searchers, function(name)
  local src = __omelette_std[name]
  if not src then return "\n\tno embedded module '" .. name .. "'" end
  local lua, err = require("omelette.compiler").compile(src)
  if not lua then return "\n\t[omelette] " .. (err and err.message or "compile error") end
  local chunk, lerr = load(lua, name)
  if not chunk then return "\n\t[omelette] " .. tostring(lerr) end
  return chunk
end)
]]
  return table.concat(parts, "\n")
end

return M
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — the bundle runs the compiler and resolves the embedded stdlib in a fresh VM (`3`, `6`, `1`), and contains no CLI. All prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add site/build.lua spec/browser_bundle_spec.lua
git commit -m "feat: browser compiler bundle (preload + embedded stdlib searcher)"
```

---

### Task 2: The site (pages, build assembly, playground, Pages workflow)

**Files:**
- Modify: `site/build.lua` (add `M.build()` + `--serve`)
- Create: `site/src/index.html`, `site/src/guide.html`, `site/src/play.html`, `site/src/style.css`, `site/src/play.js`
- Create: `site/vendor/fengari-web.js`, `site/vendor/marked.min.js`
- Create: `.github/workflows/pages.yml`
- Create: `spec/site_build_spec.lua`

**Interfaces:**
- Consumes: `build_bundle()` (Task 1), `docs/guide.md`, `omelette/*` and `std/*` sources.
- Produces: `lua site/build.lua` writes `site/dist/`; `lua site/build.lua --serve` builds then serves it.

- [ ] **Step 1: Vendor the JS libraries**

Download the two single-file libraries into `site/vendor/` (verify each URL resolves; bump the pinned version if a URL 404s):
```bash
mkdir -p site/vendor
curl -fsSL https://unpkg.com/fengari-web@0.1.4/dist/fengari-web.js -o site/vendor/fengari-web.js
curl -fsSL https://cdn.jsdelivr.net/npm/marked@4.3.0/marked.min.js -o site/vendor/marked.min.js
test -s site/vendor/fengari-web.js && test -s site/vendor/marked.min.js && echo "vendored OK"
```
(If the environment has no network, STOP and report NEEDS_CONTEXT — the main agent will vendor these.)

- [ ] **Step 2: Write the failing build test**

`spec/site_build_spec.lua`:
```lua
local h = require("spec.support.harness")
local site = require("site.build")

h.describe("site build", function()
  h.it("build() writes the expected files into site/dist", function()
    site.build()
    local expected = {
      "site/dist/index.html", "site/dist/guide.html", "site/dist/play.html",
      "site/dist/style.css", "site/dist/play.js", "site/dist/guide.md",
      "site/dist/omelette-browser.lua",
      "site/dist/fengari-web.js", "site/dist/marked.min.js",
    }
    for _, path in ipairs(expected) do
      local fh = io.open(path, "r")
      h.truthy(fh ~= nil)  -- missing: build did not produce this file
      if fh then fh:close() end
    end
  end)
  h.it("the built play.html references the bundle and fengari", function()
    site.build()
    local fh = assert(io.open("site/dist/play.html", "r")); local s = fh:read("*a"); fh:close()
    h.truthy(s:find("omelette%-browser%.lua"))
    h.truthy(s:find("fengari%-web%.js"))
  end)
end)
```

- [ ] **Step 3: Write the site source files**

`site/src/style.css` (minimal, readable, theme-light; the owner refines visuals):
```css
:root { --fg:#1a1a2e; --bg:#fdfdfd; --accent:#c0392b; --code:#f4f4f8; }
* { box-sizing: border-box; }
body { margin:0; font:16px/1.6 system-ui, sans-serif; color:var(--fg); background:var(--bg); }
header { padding:1rem 2rem; border-bottom:1px solid #eee; display:flex; gap:1.5rem; align-items:baseline; }
header a { color:var(--fg); text-decoration:none; }
header .brand { font-weight:700; color:var(--accent); font-size:1.2rem; }
main { max-width:960px; margin:0 auto; padding:2rem; }
.hero { text-align:center; padding:3rem 1rem; }
.hero h1 { font-size:2.5rem; margin:.2rem 0; }
pre, code { background:var(--code); border-radius:6px; }
pre { padding:1rem; overflow:auto; }
code { padding:.1rem .3rem; }
pre code { padding:0; background:none; }
a.button { display:inline-block; background:var(--accent); color:#fff; padding:.6rem 1.2rem; border-radius:6px; text-decoration:none; margin:.3rem; }
#editor, #output { width:100%; font-family:ui-monospace, monospace; font-size:14px; }
#editor { height:280px; padding:.8rem; border:1px solid #ccc; border-radius:6px; }
#output { white-space:pre-wrap; background:var(--code); padding:.8rem; border-radius:6px; min-height:120px; }
.controls button { font:inherit; padding:.4rem .9rem; margin:.5rem .3rem .5rem 0; cursor:pointer; }
```

`site/src/index.html`:
```html
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Omelette — an ML that compiles to Lua</title><link rel="stylesheet" href="style.css"></head>
<body>
<header><span class="brand">Omelette</span><a href="index.html">Home</a><a href="guide.html">Guide</a><a href="play.html">Playground</a><a href="https://github.com/dennyabraham/omelette-lang">GitHub</a></header>
<main>
<div class="hero">
  <h1>Omelette</h1>
  <p>A small, immutable, ML-flavored language that compiles to readable Lua 5.1.</p>
  <p><a class="button" href="guide.html">Read the guide</a><a class="button" href="play.html">Try it in your browser</a></p>
</div>
<pre><code>type Shape = | Circle { radius } | Rect { width, height } | Origin

let area s =
  match s with
  | Circle { radius }      -&gt; 3 * radius * radius
  | Rect { width, height } -&gt; width * height
  | Origin                 -&gt; 0

print(area(Circle { radius = 2 }))   -- 12</code></pre>
<h2>Why Omelette</h2>
<ul>
  <li>Compiles to clean, readable Lua 5.1 (LuaJIT / Neovim / any Lua host).</li>
  <li>Immutable values, pattern matching, sum types, comprehensions, pipes.</li>
  <li>Optional types with exhaustiveness checking — opt-in, erased at runtime.</li>
  <li>Every example in the guide is compiled and run in CI, so the docs can't drift.</li>
</ul>
</main>
</body></html>
```

`site/src/guide.html` (renders `docs/guide.md` client-side):
```html
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Omelette Guide</title><link rel="stylesheet" href="style.css"></head>
<body>
<header><span class="brand">Omelette</span><a href="index.html">Home</a><a href="guide.html">Guide</a><a href="play.html">Playground</a><a href="https://github.com/dennyabraham/omelette-lang">GitHub</a></header>
<main id="guide">Loading the guide…</main>
<script src="marked.min.js"></script>
<script>
fetch("guide.md").then(function(r){return r.text();}).then(function(md){
  document.getElementById("guide").innerHTML = marked.parse(md);
});
</script>
</body></html>
```

`site/src/play.html`:
```html
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Omelette Playground</title><link rel="stylesheet" href="style.css"></head>
<body>
<header><span class="brand">Omelette</span><a href="index.html">Home</a><a href="guide.html">Guide</a><a href="play.html">Playground</a><a href="https://github.com/dennyabraham/omelette-lang">GitHub</a></header>
<main>
<h1>Playground</h1>
<p>Runs the real Omelette compiler in your browser (via Fengari). Nothing is sent to a server.</p>
<textarea id="editor" spellcheck="false">type Shape = | Circle { radius } | Origin

let area s =
  match s with
  | Circle { radius } -&gt; 3 * radius * radius
  | Origin            -&gt; 0

print(area(Circle { radius = 3 }))
</textarea>
<div class="controls">
  <button id="run">Run</button>
  <button id="lua">Compiled Lua</button>
  <button id="check">Check types</button>
</div>
<div id="output">Loading compiler…</div>
<script src="fengari-web.js"></script>
<script src="play.js"></script>
</body></html>
```

`site/src/play.js` — wire Fengari to the bundle. Uses globals to pass source in and read output out (no string injection). **The exact Fengari calls must be verified against the vendored `fengari-web.js` in a browser (Step 5); adjust to that version's API if names differ.**
```js
(function () {
  var F = window.fengari;
  var L = F.lauxlib.luaL_newstate();
  F.lualib.luaL_openlibs(L);
  var out = document.getElementById("output");

  // load the browser bundle (sets up package.preload + the embedded-std searcher)
  fetch("omelette-browser.lua").then(function (r) { return r.text(); }).then(function (src) {
    if (F.lauxlib.luaL_dostring(L, F.to_luastring(src)) !== F.lua.LUA_OK) {
      out.textContent = "failed to load compiler: " + F.lua.lua_tojsstring(L, -1);
      return;
    }
    out.textContent = "Ready. Press Run.";
  });

  // set the Lua global __src to the editor contents, run a fixed driver, read __out
  function drive(driver) {
    var editorSrc = document.getElementById("editor").value;
    F.lua.lua_pushstring(L, F.to_luastring(editorSrc));
    F.lua.lua_setglobal(L, F.to_luastring("__src"));
    if (F.lauxlib.luaL_dostring(L, F.to_luastring(driver)) !== F.lua.LUA_OK) {
      out.textContent = "internal error: " + F.lua.lua_tojsstring(L, -1);
      return;
    }
    F.lua.lua_getglobal(L, F.to_luastring("__out"));
    out.textContent = F.lua.lua_tojsstring(L, -1) || "";
    F.lua.lua_pop(L, 1);
  }

  var RUN = [
    "local c = require('omelette.compiler')",
    "local buf, oldprint = {}, print",
    "print = function(...) local t={} for i=1,select('#',...) do t[i]=tostring((select(i,...))) end buf[#buf+1]=table.concat(t,'\\t') end",
    "local mod, err = c.eval(__src)",
    "print = oldprint",
    "if err then __out = '[error] '..tostring(err.message) else __out = table.concat(buf, '\\n') end",
  ].join("\n");

  var LUA = "local lua, err = require('omelette.compiler').compile(__src); __out = lua or ('[error] '..(err and err.message or '?'))";

  var CHECK = [
    "local d, err = require('omelette.compiler').check(__src)",
    "if err then __out = '[error] '..tostring(err.message)",
    "elseif #d == 0 then __out = 'No type errors.'",
    "else local t={} for i,x in ipairs(d) do t[i]=x.message end __out = table.concat(t, '\\n') end",
  ].join("\n");

  document.getElementById("run").onclick = function () { drive(RUN); };
  document.getElementById("lua").onclick = function () { drive(LUA); };
  document.getElementById("check").onclick = function () { drive(CHECK); };
})();
```

- [ ] **Step 4: Implement `M.build()` + `--serve` in `site/build.lua`**

Append to `site/build.lua` (before `return M`):
```lua
local function write(path, data)
  local fh = assert(io.open(path, "w"), "cannot write " .. path)
  fh:write(data); fh:close()
end

local function copy(from, to) write(to, read(from)) end

function M.build()
  os.execute("mkdir -p site/dist")
  write("site/dist/omelette-browser.lua", M.build_bundle())
  copy("docs/guide.md", "site/dist/guide.md")
  for _, f in ipairs({ "index.html", "guide.html", "play.html", "style.css", "play.js" }) do
    copy("site/src/" .. f, "site/dist/" .. f)
  end
  for _, f in ipairs({ "fengari-web.js", "marked.min.js" }) do
    copy("site/vendor/" .. f, "site/dist/" .. f)
  end
end

-- run directly: `lua site/build.lua [--serve]`
if arg and arg[0] and arg[0]:find("build") and not package.loaded["spec.support.harness"] then
  M.build()
  io.write("built site/dist/\n")
  if arg[1] == "--serve" then
    io.write("serving http://localhost:8000  (Ctrl-C to stop)\n")
    os.execute("cd site/dist && python3 -m http.server 8000")
  end
end
```

- [ ] **Step 5: Build and verify locally (manual, required)**

Run: `luajit spec/run.lua` → the `site_build_spec` + `browser_bundle_spec` are green.
Then build and open the site in a browser to verify the **playground actually works** (the one thing tests can't cover):
```
lua site/build.lua
cd site/dist && python3 -m http.server 8000    # open http://localhost:8000
```
Confirm in the browser: the landing renders; the guide renders from `guide.md`; in the playground, **Run** prints `12` for the seeded example, **Compiled Lua** shows Lua, **Check** reports no type errors (and reports one for `let x: number = "hi"`). If the Fengari API calls in `play.js` don't match the vendored version, fix them against that version until the playground works. Record the verified-working state in the report.

- [ ] **Step 6: Add the (unpublished) Pages workflow**

`.github/workflows/pages.yml`:
```yaml
name: Pages (manual)
# Manual only — the site is NOT auto-published. Publishing also requires enabling
# GitHub Pages in repo settings (kept OFF until the site is reviewed + the prose
# is rewritten). This job only builds and uploads the artifact when dispatched.
on:
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: leafo/gh-actions-lua@v13
        with:
          luaVersion: "luajit"
      - name: Build site
        run: lua site/build.lua
      - uses: actions/upload-pages-artifact@v3
        with:
          path: site/dist
```
(No `deploy` job / no `push` trigger — dispatching only uploads the artifact; a deploy step is added later, deliberately, when publishing.)

- [ ] **Step 7: Commit**

```bash
git add site/ .github/workflows/pages.yml spec/site_build_spec.lua
git commit -m "feat: static site + Fengari playground (built locally, unpublished)"
```

---

## Self-Review

**1. Spec coverage:**
- Browser bundle (preload incl. typecheck, embedded std, browser searcher, no CLI) → Task 1. ✓
- Fresh-VM verification of compiler + embedded stdlib + typecheck → Task 1 test. ✓
- 3 pages (landing/guide/playground), guide rendered from `docs/guide.md` via marked → Task 2. ✓
- Playground runs compile/eval/check client-side via Fengari → Task 2 `play.js` + manual verify. ✓
- No-build Lua assembly + `--serve` local review → Task 2 `M.build()`. ✓
- Vendored fengari-web + marked (single files) → Task 2 Step 1. ✓
- Pages workflow present but `workflow_dispatch`-only, Pages OFF, not published → Task 2 Step 6. ✓
- Build-output test → Task 2 `site_build_spec`. ✓
- Deferred (iambic rewrite, publishing, highlighter) → not implemented (correct). ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". The bundle builder, all HTML/CSS/JS, `M.build()`, the workflow, and both tests are given in full. The one irreducible external step — verifying `play.js` against the actual vendored Fengari API — is an explicit manual browser gate (Step 5), not a placeholder: front-end integration with a third-party lib legitimately requires in-browser confirmation, and the plan states exactly what to confirm and that the bundle (the testable core) is already proven in Lua.

**3. Type consistency:** `M.build_bundle()` (Task 1) returns the bundle string that `M.build()` (Task 2) writes to `dist/omelette-browser.lua`, which `play.js` `fetch`es and `luaL_dostring`s. `read`/`write`/`copy` helpers share one definition (`read` in Task 1, `write`/`copy` added in Task 2). The bundle's embedded-std searcher and `play.js`'s `require("omelette.compiler")` calls match the module names the bundle preloads. `site_build_spec` asserts exactly the files `M.build()` writes. ✓
