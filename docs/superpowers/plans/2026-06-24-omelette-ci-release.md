# Omelette CI & Release Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub Actions CI (test suite under LuaJIT + Lua 5.4) and tag-driven release automation (validate → test → build a single-file `omelette` → GitHub Release → conditional LuaRocks).

**Architecture:** Testable Lua scripts (`scripts/check-version.lua`, `scripts/changelog.lua`, `build/amalgamate.lua`) covered by the existing harness, plus two workflow YAMLs, a rockspec template, and a CHANGELOG. All files are disjoint from the compiler (`omelette/`, `std/`), so this is independent of language work.

**Tech Stack:** GitHub Actions, `leafo/gh-actions-lua`, LuaRocks; pure-Lua scripts tested under `luajit`.

## Global Constraints

- Version source of truth is `omelette/init.lua`'s `version` field (currently `"0.1.0"`); the `vX.Y.Z` tag must match it.
- CI matrix: **LuaJIT and Lua 5.4**. Test command: `lua spec/run.lua` (the action installs the chosen interpreter as `lua`).
- The single-file artifact bundles `omelette/*.lua` via `package.preload`; modules: `lexer, errors, resolver, parser, codegen, compiler, searcher, repl, cli, init` (init = the `omelette` module).
- LuaRocks publish is **conditional**: only when the repo is public AND `secrets.LUAROCKS_API_KEY` is set.
- Repo: `dennyabraham/omelette-lang`. License: MIT.
- Scripts are required from tests as `scripts.check-version` / `scripts.changelog` / `build.amalgamate` (package.path includes `./?.lua`); their "run as a script" blocks are guarded by an `arg[0]` check so requiring them never executes the script body.

---

### Task 1: Version-check & changelog-extract scripts

**Files:**
- Create: `scripts/check-version.lua`
- Create: `scripts/changelog.lua`
- Create: `spec/release_scripts_spec.lua`

**Interfaces:**
- Produces: `check(tag, version) -> ok, msg`; `read_init_version(path) -> version|nil`; `extract(text, version) -> section|nil`.

- [ ] **Step 1: Write the failing test**

`spec/release_scripts_spec.lua`:
```lua
local h = require("spec.support.harness")
local cv = require("scripts.check-version")
local cl = require("scripts.changelog")

h.describe("check-version", function()
  h.it("accepts a matching vX.Y.Z tag", function()
    local ok = cv.check("v1.2.3", "1.2.3")
    h.truthy(ok)
  end)
  h.it("rejects a mismatched tag", function()
    local ok, msg = cv.check("v1.2.3", "1.2.4")
    h.truthy(not ok)
    h.truthy(msg:find("1.2.4"))
  end)
  h.it("rejects a malformed tag", function()
    h.truthy(not (cv.check("1.2.3", "1.2.3")))   -- missing leading v
    h.truthy(not (cv.check("vx", "1.2.3")))
  end)
  h.it("reads the version out of an init.lua-style string via a temp file", function()
    local p = os.tmpname()
    local fh = io.open(p, "w"); fh:write('return {\n  version = "9.8.7",\n}\n'); fh:close()
    h.eq(cv.read_init_version(p), "9.8.7")
    os.remove(p)
  end)
end)

h.describe("changelog", function()
  local sample = table.concat({
    "# Changelog",
    "",
    "## [1.1.0]",
    "- added b",
    "",
    "## [1.0.0]",
    "- initial",
  }, "\n")
  h.it("extracts a version's section", function()
    local s = cl.extract(sample, "1.1.0")
    h.truthy(s:find("added b"))
    h.truthy(not s:find("initial"))
  end)
  h.it("extracts the last version's section", function()
    h.truthy(cl.extract(sample, "1.0.0"):find("initial"))
  end)
  h.it("returns nil for a missing version", function()
    h.eq(cl.extract(sample, "9.9.9"), nil)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `module 'scripts.check-version' not found`.

- [ ] **Step 3: Implement**

`scripts/check-version.lua`:
```lua
-- Assert a vX.Y.Z tag matches omelette/init.lua's version.
-- Required as a module by tests; runs the check when executed directly.
local M = {}

function M.check(tag, version)
  local stripped = tag and tag:match("^v(%d+%.%d+%.%d+)$")
  if not stripped then return false, "tag '" .. tostring(tag) .. "' is not of the form vX.Y.Z" end
  if stripped ~= version then
    return false, "tag " .. tag .. " does not match init.lua version " .. tostring(version)
  end
  return true, nil
end

function M.read_init_version(path)
  local fh = io.open(path or "omelette/init.lua", "r")
  if not fh then return nil end
  local src = fh:read("*a"); fh:close()
  return src:match('version%s*=%s*"([^"]+)"')
end

-- run directly: `luajit scripts/check-version.lua vX.Y.Z`
if arg and arg[0] and arg[0]:find("check%-version") then
  local version = M.read_init_version("omelette/init.lua")
  local ok, msg = M.check(arg[1], version)
  if not ok then io.stderr:write("version check failed: " .. tostring(msg) .. "\n"); os.exit(1) end
  io.write("version ok: " .. tostring(arg[1]) .. "\n")
  os.exit(0)
end

return M
```

`scripts/changelog.lua`:
```lua
-- Extract a version's section from a Keep-a-Changelog document.
local M = {}

-- extract(text, version) -> the lines under `## [version]` up to the next `## [` (or EOF)
function M.extract(text, version)
  local lines, capturing, out = {}, false, {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  local header = "## %[" .. version:gsub("%.", "%%.") .. "%]"
  for _, line in ipairs(lines) do
    if line:match("^## %[") then
      if capturing then break end
      if line:match("^" .. header) then capturing = true end
    elseif capturing then
      out[#out + 1] = line
    end
  end
  if not capturing then return nil end
  -- trim leading/trailing blank lines
  while out[1] == "" do table.remove(out, 1) end
  while out[#out] == "" do table.remove(out) end
  if #out == 0 then return nil end
  return table.concat(out, "\n")
end

-- run directly: `luajit scripts/changelog.lua VERSION < CHANGELOG.md` (prints the section)
if arg and arg[0] and arg[0]:find("changelog") and arg[1] then
  local text = io.read("*a") or ""
  local s = M.extract(text, arg[1])
  if not s then io.stderr:write("no changelog section for " .. arg[1] .. "\n"); os.exit(1) end
  io.write(s .. "\n")
  os.exit(0)
end

return M
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — release-script tests green, all prior tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/check-version.lua scripts/changelog.lua spec/release_scripts_spec.lua
git commit -m "feat: testable version-check and changelog-extract scripts"
```

---

### Task 2: Single-file amalgamation

**Files:**
- Create: `build/amalgamate.lua`
- Create: `spec/amalgamate_spec.lua`
- Create: `.gitignore` (append `dist/`)

**Interfaces:**
- Produces: `build() -> string` — the bundled single-file `omelette` script source.

- [ ] **Step 1: Write the failing test**

`spec/amalgamate_spec.lua`:
```lua
local h = require("spec.support.harness")
local amalg = require("build.amalgamate")

h.describe("amalgamate", function()
  h.it("bundles every module as a package.preload entry plus a bootstrap", function()
    local out = amalg.build()
    h.truthy(out:find('package.preload%["omelette.lexer"%]'))
    h.truthy(out:find('package.preload%["omelette.codegen"%]'))
    h.truthy(out:find('package.preload%["omelette"%]'))      -- init.lua
    h.truthy(out:find('require%("omelette.cli"%).main'))     -- bootstrap
    h.truthy(out:find("^#!/usr/bin/env lua"))                -- shebang
  end)
  h.it("the bundled module bodies are present (e.g. the lexer's tokenize)", function()
    local out = amalg.build()
    h.truthy(out:find("function M.tokenize"))
  end)
end)
```
(The end-to-end "does the bundle actually run" check is an integration step in CI — Task 4 — not a unit test, to avoid polluting the test process's `package.preload`.)

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — `module 'build.amalgamate' not found`.

- [ ] **Step 3: Implement**

`build/amalgamate.lua`:
```lua
-- Bundle omelette/*.lua into one self-contained `omelette` script via package.preload.
local M = {}

local MODULES = {
  "lexer", "errors", "resolver", "parser", "codegen",
  "compiler", "searcher", "repl", "cli", "init",
}

local function read(path)
  local fh = assert(io.open(path, "r"), "cannot read " .. path)
  local s = fh:read("*a"); fh:close()
  return s
end

function M.build()
  local parts = { "#!/usr/bin/env lua" }
  for _, name in ipairs(MODULES) do
    local mod = (name == "init") and "omelette" or ("omelette." .. name)
    parts[#parts + 1] = 'package.preload["' .. mod .. '"] = function(...)'
    parts[#parts + 1] = read("omelette/" .. name .. ".lua")
    parts[#parts + 1] = "end"
  end
  parts[#parts + 1] = 'return require("omelette.cli").main(arg)'
  return table.concat(parts, "\n")
end

-- run directly: `luajit build/amalgamate.lua > dist/omelette`
if arg and arg[0] and arg[0]:find("amalgamate") then
  io.write(M.build())
  os.exit(0)
end

return M
```

`.gitignore` (create or append the line):
```
dist/
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Then smoke-build locally:
Run: `mkdir -p dist && luajit build/amalgamate.lua > dist/omelette && luajit dist/omelette build spec/fixtures/hello.egg`
Expected: tests PASS; the bundled script prints a Lua module containing `function M.greet`.

- [ ] **Step 5: Commit**

```bash
git add build/amalgamate.lua spec/amalgamate_spec.lua .gitignore
git commit -m "feat: single-file amalgamation build"
```

---

### Task 3: CHANGELOG and rockspec template

**Files:**
- Create: `CHANGELOG.md`
- Create: `rockspecs/omelette.rockspec.template`

**Interfaces:**
- Consumes: nothing. Produces: a changelog section the release workflow extracts, and a rockspec the workflow renders.

- [ ] **Step 1: Create `CHANGELOG.md`**

```markdown
# Changelog

All notable changes to Omelette are documented here (Keep a Changelog format).

## [0.1.0]
- Initial release: ML-flavored language transpiling to Lua 5.1.
- Lexer, parser, codegen, compiler, CLI, REPL, `require` integration.
- List comprehensions, `[a to b]` ranges, key/value generators, `xs[i]` indexing, `#xs` length.
- Standard library: `std.list`, `std.string`, `std.table`.
```

- [ ] **Step 2: Create `rockspecs/omelette.rockspec.template`**

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

- [ ] **Step 3: Verify rockspec template is syntactically loadable Lua (with placeholders quoted)**

Run: `luajit -e 'local s=io.open("rockspecs/omelette.rockspec.template"):read("*a"); s=s:gsub("@VERSION@","0.0.0"):gsub("@TAG@","v0.0.0"); assert(load(s)); print("rockspec ok")'`
Expected: prints `rockspec ok` (the rendered template is valid Lua).

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md rockspecs/omelette.rockspec.template
git commit -m "feat: changelog and rockspec template"
```

---

### Task 4: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `spec/run.lua`, `build/amalgamate.lua`, `spec/fixtures/hello.egg`.

- [ ] **Step 1: Create `.github/workflows/ci.yml`**

```yaml
name: CI
on:
  push:
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        lua: ["luajit-2.1.0-beta3", "5.4"]
    steps:
      - uses: actions/checkout@v4
      - uses: leafo/gh-actions-lua@v10
        with:
          luaVersion: ${{ matrix.lua }}
      - name: Run test suite
        run: lua spec/run.lua
      - name: Amalgamation smoke test
        run: |
          mkdir -p dist
          lua build/amalgamate.lua > dist/omelette
          lua dist/omelette build spec/fixtures/hello.egg | grep -q "function M.greet"
```

- [ ] **Step 2: Validate the YAML parses**

Run: `luajit -e 'local f=io.open(".github/workflows/ci.yml"); assert(f, "ci.yml missing"); f:close(); print("ci.yml present")'`
(YAML can't be unit-tested here; verify presence and that the indentation is consistent by reading it.)
Expected: prints `ci.yml present`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: test suite under LuaJIT and Lua 5.4 + amalgamation smoke"
```

---

### Task 5: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `scripts/check-version.lua`, `scripts/changelog.lua`, `build/amalgamate.lua`, `rockspecs/omelette.rockspec.template`, `CHANGELOG.md`.

- [ ] **Step 1: Create `.github/workflows/release.yml`**

```yaml
name: Release
on:
  push:
    tags:
      - "v*"

jobs:
  release:
    runs-on: ubuntu-latest
    env:
      HAS_ROCKS_KEY: ${{ secrets.LUAROCKS_API_KEY != '' }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: leafo/gh-actions-lua@v10
        with:
          luaVersion: "luajit-2.1.0-beta3"
      - uses: leafo/gh-actions-luarocks@v4
      - name: Validate tag matches init.lua version
        run: lua scripts/check-version.lua "${GITHUB_REF_NAME}"
      - name: Run test suite
        run: lua spec/run.lua
      - name: Build single-file omelette
        run: |
          mkdir -p dist
          lua build/amalgamate.lua > dist/omelette
          chmod +x dist/omelette
      - name: Smoke-test the artifact
        run: lua dist/omelette build spec/fixtures/hello.egg | grep -q "function M.greet"
      - name: Extract release notes
        run: lua scripts/changelog.lua "${GITHUB_REF_NAME#v}" < CHANGELOG.md > RELEASE_NOTES.md
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          body_path: RELEASE_NOTES.md
          files: dist/omelette
      - name: Publish to LuaRocks
        if: ${{ env.HAS_ROCKS_KEY == 'true' && github.event.repository.private == false }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          sed -e "s/@VERSION@/${VERSION}/g" -e "s/@TAG@/${GITHUB_REF_NAME}/g" \
            rockspecs/omelette.rockspec.template > "omelette-${VERSION}-1.rockspec"
          luarocks upload "omelette-${VERSION}-1.rockspec" --api-key="${{ secrets.LUAROCKS_API_KEY }}"
```

- [ ] **Step 2: Validate presence + the version/changelog scripts the workflow calls**

Run: `luajit -e 'assert(io.open(".github/workflows/release.yml")); print("release.yml present")'`
Run: `lua scripts/check-version.lua v0.1.0 && lua scripts/changelog.lua 0.1.0 < CHANGELOG.md`
Expected: `release.yml present`; `version ok: v0.1.0`; and the 0.1.0 changelog section prints.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: tag-driven release (validate, build, GitHub Release, conditional LuaRocks)"
```

---

## Self-Review

**1. Spec coverage:**
- CI under LuaJIT + Lua 5.4 + amalgamation smoke → Task 4. ✓
- Release on `v*` tag: validate → test → build → smoke → GitHub Release → conditional LuaRocks → Task 5. ✓
- Version source of truth = init.lua; tag must match (validated) → Task 1 (`check`/`read_init_version`) + Task 5 step. ✓
- Single-file amalgamation via `package.preload` → Task 2. ✓
- Rockspec template (git source, `@VERSION@`/`@TAG@`) → Task 3. ✓
- Changelog extraction → Task 1 (`extract`) + Task 5 step. ✓
- LuaRocks conditional on public + key → Task 5 `if` guard. ✓
- Tooling testable under the harness → Tasks 1, 2 specs. ✓
- `.gitignore dist/` → Task 2. ✓

No gaps. Workflows (YAML) are config, verified by presence + the scripts they call; a real tag/push exercises them end-to-end.

**2. Placeholder scan:** `@VERSION@`/`@TAG@` are intentional template tokens (rendered by `sed` in Task 5). No TBD/TODO. Each script step shows complete code.

**3. Type consistency:** `check`/`read_init_version`/`extract` signatures match between Task 1's scripts and the Task 5 workflow invocations (`check-version.lua "$TAG"`, `changelog.lua "$VERSION"`). The amalgamate `MODULES` list matches the rockspec `modules` table (same 10 modules; init = the `omelette` module). The `leafo/gh-actions-lua` `luaVersion` values are valid for that action.
