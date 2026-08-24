# Stdlib Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `require("std.*")` resolve without a repo checkout, in both the single-file `omelette` binary and a LuaRocks install.

**Architecture:** One shared build helper (`build/build-std.lua`) compiles `std/*.egg` → Lua at build time. The amalgam inlines that compiled Lua as `package.preload["std.*"]` entries; the LuaRocks rock uses a command build that runs the same helper to emit installed `std/*.lua` modules. `std/*.egg` stays the sole committed source of truth — nothing generated is committed.

**Tech Stack:** Pure Lua 5.1+ (LuaJIT + Lua 5.4 in CI); the existing `omelette.compiler`; the project's `spec/support/harness.lua` test harness; LuaRocks `rockspec_format = "3.0"`.

## Global Constraints

- Runs on both LuaJIT and Lua 5.4 (CI matrix). Any subprocess spawn MUST use the running interpreter via `interp = (arg and arg[-1]) or "lua"`, never a hardcoded `luajit` (the Lua 5.4 CI leg has no `luajit` binary).
- `std/*.egg` is the only committed source of truth; do NOT commit any generated `.lua`.
- `omelette/searcher.lua` and `omelette/cli.lua` are unchanged — the `.egg` searcher still resolves a user's own project-local modules.
- The std module list is fixed: `std.list`, `std.string`, `std.table` (files `std/list.egg`, `std/string.egg`, `std/table.egg`).
- `compiler.compile(source)` returns `lua_string, nil` on success or `nil, err` on failure, where `err.message` is a string.
- Test harness API: `h.describe(name, fn)`, `h.it(name, fn)`, `h.eq(a, b)`, `h.truthy(v)`, `h.throws(fn)` (returns true if `fn` errors). Load with `local h = require("spec.support.harness")`. Run the whole suite with `luajit spec/run.lua`.

---

### Task 1: `build/build-std.lua` — the shared compile helper

**Files:**
- Create: `build/build-std.lua`
- Test: `spec/build_std_spec.lua`

**Interfaces:**
- Consumes: `omelette.compiler` (`compiler.compile(source) -> lua|nil, err`).
- Produces:
  - `M.STD` → `{ "std.list", "std.string", "std.table" }`
  - `M.source(modname)` → `.egg` source string (raises on read failure)
  - `M.compile(modname)` → compiled Lua string (raises, naming the module, on compile failure)
  - `M.compile_all()` → array of `{ module = <modname>, lua = <string> }`, in `M.STD` order
  - `M.preload_block()` → Lua source string of `package.preload["std.X"] = function(...) <lua> end` blocks (consumed by Task 2)
  - `M.write_lua(outdir)` → writes `<outdir>/std/<leaf>.lua` per module, returns list of paths (consumed by Task 3's rock build)

- [ ] **Step 1: Write the failing test**

Create `spec/build_std_spec.lua`:

```lua
local h = require("spec.support.harness")
local bs = require("build.build-std")

local function loads(lua)
  local f = (loadstring or load)(lua)
  return f ~= nil
end

h.describe("build-std (compile std/*.egg at build time)", function()
  h.it("STD lists the three stdlib modules", function()
    h.eq(table.concat(bs.STD, ","), "std.list,std.string,std.table")
  end)

  h.it("compile_all returns one loadable Lua chunk per module", function()
    local all = bs.compile_all()
    h.eq(#all, 3)
    for _, m in ipairs(all) do
      h.truthy(m.lua:find("return M"))   -- each std module ends in `return M`
      h.truthy(loads(m.lua))             -- and the emitted Lua parses
    end
  end)

  h.it("preload_block emits a loadable package.preload entry per module", function()
    local block = bs.preload_block()
    h.truthy(block:find('package.preload%["std.list"%] = function'))
    h.truthy(block:find('package.preload%["std.string"%] = function'))
    h.truthy(block:find('package.preload%["std.table"%] = function'))
    h.truthy(loads(block))               -- the whole block is valid Lua
  end)

  h.it("a missing module raises (a broken build must fail loudly)", function()
    h.truthy(h.throws(function() bs.compile("std.nope") end))
  end)

  h.it("write_lua writes one std/<leaf>.lua per module", function()
    local dir = os.tmpname() .. "_std"
    local paths = bs.write_lua(dir)
    h.eq(#paths, 3)
    local fh = assert(io.open(dir .. "/std/list.lua", "r"))
    local body = fh:read("*a"); fh:close()
    h.truthy(body:find("return M"))
    os.execute('rm -rf "' .. dir .. '"')
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit spec/run.lua 2>&1 | grep -i "build-std\|error\|fail" | head`
Expected: FAIL — `module 'build.build-std' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `build/build-std.lua`:

```lua
-- Compile std/*.egg -> Lua at BUILD time. std/*.egg stays the sole committed source of
-- truth; nothing generated here is committed. Consumed by build/amalgamate.lua
-- (preload_block, inlined into the single-file binary) and the LuaRocks command build
-- (write_lua, emits installed std/*.lua). Reads std/ and requires omelette.compiler
-- relative to CWD, which is the repo root in every caller (amalgamate, the rock build,
-- the test suite).
local compiler = require("omelette.compiler")
local M = {}

M.STD = { "std.list", "std.string", "std.table" }

local function leaf(modname) return (modname:gsub("^std%.", "")) end

local function read(path)
  local fh = assert(io.open(path, "r"), "build-std: cannot read " .. path)
  local s = fh:read("*a"); fh:close()
  return s
end

function M.source(modname)
  return read("std/" .. leaf(modname) .. ".egg")
end

function M.compile(modname)
  local lua, err = compiler.compile(M.source(modname))
  if not lua then
    error("build-std: compiling " .. modname .. " failed: " .. (err and err.message or "?"))
  end
  return lua
end

function M.compile_all()
  local out = {}
  for _, name in ipairs(M.STD) do
    out[#out + 1] = { module = name, lua = M.compile(name) }
  end
  return out
end

function M.preload_block()
  local parts = {}
  for _, m in ipairs(M.compile_all()) do
    parts[#parts + 1] = 'package.preload["' .. m.module .. '"] = function(...)'
    parts[#parts + 1] = m.lua
    parts[#parts + 1] = "end"
  end
  return table.concat(parts, "\n")
end

function M.write_lua(outdir)
  os.execute('mkdir -p "' .. outdir .. '/std"')
  local written = {}
  for _, m in ipairs(M.compile_all()) do
    local path = outdir .. "/std/" .. leaf(m.module) .. ".lua"
    local fh = assert(io.open(path, "w"), "build-std: cannot write " .. path)
    fh:write(m.lua); fh:close()
    written[#written + 1] = path
  end
  return written
end

-- run directly: `lua build/build-std.lua <outdir>` — the LuaRocks build_command entry point.
-- Guarded on arg[0] so `dofile`/`require` from another script never triggers it.
if arg and arg[0] and arg[0]:find("build%-std") then
  local outdir = arg[1] or "build-out"
  for _, p in ipairs(M.write_lua(outdir)) do io.write(p .. "\n") end
  os.exit(0)
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: the full suite passes (previously 291, now higher — new `build-std` cases green, 0 failures).

- [ ] **Step 5: Verify the direct-run entry point works**

Run: `lua build/build-std.lua /tmp/bs-check && head -1 /tmp/bs-check/std/list.lua && rm -rf /tmp/bs-check`
Expected: prints three `/tmp/bs-check/std/*.lua` paths, then `local M = {}`.

- [ ] **Step 6: Commit**

```bash
git add build/build-std.lua spec/build_std_spec.lua
git commit -m "feat(build): build-std helper compiles std/*.egg to Lua"
```

---

### Task 2: Amalgam inlines the std preload block (self-contained binary)

**Files:**
- Modify: `build/amalgamate.lua`
- Test: `spec/amalgamate_spec.lua` (extend)

**Interfaces:**
- Consumes: `build.build-std` `M.preload_block()` (Task 1).
- Produces: `amalg.build()` output now contains `package.preload["std.list"]` … entries before the `os.exit(require("omelette.cli").main(arg))` bootstrap.

- [ ] **Step 1: Write the failing tests**

Append to `spec/amalgamate_spec.lua`, inside the existing `h.describe("amalgamate", function() … end)` block (before its closing `end)`):

```lua
  h.it("bundles the stdlib as package.preload entries (self-contained std)", function()
    local out = amalg.build()
    h.truthy(out:find('package.preload%["std.list"%]'))
    h.truthy(out:find('package.preload%["std.string"%]'))
    h.truthy(out:find('package.preload%["std.table"%]'))
    -- the std preload must precede the bootstrap so std is registered before main runs
    h.truthy(out:find('package.preload%["std.list"%]') < out:find('os%.exit%(require%("omelette.cli"%)'))
  end)

  h.it("the single-file binary resolves require(\"std.list\") from OUTSIDE the repo", function()
    -- write the binary + a std-using program into a temp dir with NO ./std/, then run it
    -- there. A printed result proves std came from the embedded preload, not ./std/*.egg —
    -- exactly an installed single-file omelette run from an arbitrary cwd. `; echo EXIT=$?`
    -- captures the exit code portably (LuaJIT's io.popen:close does not return it).
    local dir = os.tmpname() .. "_std"
    os.execute('mkdir -p "' .. dir .. '"')
    local function put(name, data) local f = assert(io.open(dir .. "/" .. name, "w")); f:write(data); f:close() end
    put("omelette", amalg.build())
    put("prog.egg", 'let list = require("std.list")\nprint(list.sum([1, 2, 3, 4]))\n')
    local interp = (arg and arg[-1]) or "lua"   -- luajit locally; `lua` on both CI legs
    local p = io.popen('cd "' .. dir .. '" && "' .. interp .. '" omelette run prog.egg 2>&1; echo EXIT=$?')
    local out = p:read("*a"); p:close()
    h.truthy(out:find("10", 1, true))            -- list.sum([1,2,3,4]) == 10
    h.truthy(not out:find("not found", 1, true)) -- NOT a missing-module crash
    h.truthy(out:find("EXIT=0", 1, true))        -- clean exit
    os.execute('rm -rf "' .. dir .. '"')
  end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `luajit spec/run.lua 2>&1 | grep -i "std\|fail" | head`
Expected: FAIL — `amalg.build()` output has no `package.preload["std.list"]` yet, so both new cases fail.

- [ ] **Step 3: Implement — require the helper and append its block**

In `build/amalgamate.lua`, add the require near the top (after `local M = {}`):

```lua
local build_std = require("build.build-std")
```

Then in `M.build()`, insert the std preload block immediately before the bootstrap line. Change:

```lua
  -- os.exit with the CLI's status (a top-level `return` is ignored, so the
  -- single-file binary would otherwise always exit 0 — breaking `check` in scripts)
  parts[#parts + 1] = 'os.exit(require("omelette.cli").main(arg))'
```

to:

```lua
  -- embed the stdlib as package.preload["std.*"] so `require("std.list")` resolves from any
  -- cwd (Lua's preload searcher precedes the .egg searcher); std/*.egg compiled at build time
  parts[#parts + 1] = build_std.preload_block()
  -- os.exit with the CLI's status (a top-level `return` is ignored, so the
  -- single-file binary would otherwise always exit 0 — breaking `check` in scripts)
  parts[#parts + 1] = 'os.exit(require("omelette.cli").main(arg))'
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: full suite passes, 0 failures.

- [ ] **Step 5: Manually confirm the real binary works from /tmp**

Run:
```bash
lua build/amalgamate.lua > /tmp/om && chmod +x /tmp/om
mkdir -p /tmp/omtest && printf 'let list = require("std.list")\nprint(list.sum([1,2,3,4]))\n' > /tmp/omtest/p.egg
(cd /tmp/omtest && lua /tmp/om run p.egg); rm -rf /tmp/omtest /tmp/om
```
Expected: prints `10` (today it prints `module 'std.list' not found`).

- [ ] **Step 6: Commit**

```bash
git add build/amalgamate.lua spec/amalgamate_spec.lua
git commit -m "feat(build): embed stdlib in the amalgam so require(std.*) resolves anywhere"
```

---

### Task 3: LuaRocks command build (ships std + typecheck)

**Files:**
- Modify: `rockspecs/omelette.rockspec.template`
- Test: `spec/rockspec_spec.lua`

**Interfaces:**
- Consumes: `build/build-std.lua`'s direct-run entry point (`lua build/build-std.lua build-out` writes `build-out/std/*.lua`).
- Produces: a rockspec whose `build.type == "command"`, whose `build_command` runs the helper, and whose `install_command` installs `omelette/*.lua` (glob includes `typecheck.lua`), `build-out/std/*.lua`, and `bin/omelette`.

- [ ] **Step 1: Write the failing test**

Create `spec/rockspec_spec.lua`:

```lua
local h = require("spec.support.harness")

-- Render the @VERSION@/@TAG@ template, then load it as a Lua chunk in a sandbox and read
-- the globals a rockspec sets (package/version/build/...). Portable across 5.1 (setfenv)
-- and 5.4 (load with an env argument).
local function load_rockspec()
  local fh = assert(io.open("rockspecs/omelette.rockspec.template", "r"))
  local src = fh:read("*a"); fh:close()
  src = src:gsub("@VERSION@", "0.1.0"):gsub("@TAG@", "v0.1.0")
  -- __index = _G so the rockspec can reach any stdlib it references; assignments still
  -- land in `env`, so the rockspec's globals (package/version/build/...) are captured there.
  local env = setmetatable({}, { __index = _G })
  if setfenv then
    local chunk = assert(loadstring(src, "rockspec"))
    setfenv(chunk, env); chunk()
  else
    local chunk = assert(load(src, "rockspec", "t", env))
    chunk()
  end
  return env
end

h.describe("rockspec template", function()
  local rock = load_rockspec()

  h.it("renders the version and tag", function()
    h.eq(rock.version, "0.1.0-1")
    h.eq(rock.source.tag, "v0.1.0")
  end)

  h.it("uses a command build that compiles std via build-std", function()
    h.eq(rock.build.type, "command")
    h.truthy(rock.build.build_command:find("build/build%-std.lua"))
  end)

  h.it("installs the omelette modules (glob covers typecheck), std, and the binary", function()
    local inst = rock.build.install_command
    h.truthy(inst:find("omelette/%*.lua"))     -- all omelette/*.lua incl. typecheck.lua
    h.truthy(inst:find("build%-out/std"))       -- the compiled std modules
    h.truthy(inst:find("bin/omelette"))         -- the CLI entry point
    h.truthy(inst:find("%$%(LUADIR%)"))         -- into LuaRocks' Lua module dir
    h.truthy(inst:find("%$%(BINDIR%)"))         -- and its binary dir
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `luajit spec/run.lua 2>&1 | grep -i "rockspec\|fail" | head`
Expected: FAIL — the current template has `build.type == "builtin"`, so the command-build assertions fail.

- [ ] **Step 3: Rewrite the build table in the template**

In `rockspecs/omelette.rockspec.template`, replace the entire `build = { … }` block:

```lua
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

with a command build (compiles std at install; the `omelette/*.lua` glob installs every
module, including the previously-missing `omelette.typecheck`):

```lua
build = {
  -- A command build: std/*.egg must be compiled to Lua at install time (a `builtin` build
  -- cannot run a compile step), and nothing generated is committed. build-std writes the
  -- compiled std into build-out/std/, then everything is copied into LuaRocks' locations.
  -- The omelette/*.lua glob installs all modules, including omelette.typecheck.
  type = "command",
  build_command = "lua build/build-std.lua build-out",
  -- plain string concatenation (the `..` operator needs no stdlib), so the rockspec loads in
  -- a bare sandbox; $(LUADIR)/$(BINDIR) are LuaRocks' install-location substitutions.
  install_command =
    "mkdir -p $(LUADIR)/omelette $(LUADIR)/std $(BINDIR) && " ..
    "cp omelette/*.lua $(LUADIR)/omelette/ && " ..
    "cp build-out/std/*.lua $(LUADIR)/std/ && " ..
    "cp bin/omelette $(BINDIR)/omelette && " ..
    "chmod +x $(BINDIR)/omelette",
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: full suite passes, 0 failures.

- [ ] **Step 5: Sanity-check the build_command end-to-end locally (the compile half)**

Run: `lua build/build-std.lua build-out && ls build-out/std && rm -rf build-out`
Expected: lists `list.lua  string.lua  table.lua`. (The `install_command` copy half uses
LuaRocks' `$(LUADIR)`/`$(BINDIR)` and is only exercised by a real `luarocks build` once the
repo is public — that is the deferred end-to-end verification.)

- [ ] **Step 6: Commit**

```bash
git add rockspecs/omelette.rockspec.template spec/rockspec_spec.lua
git commit -m "feat(rock): command build compiles std at install; fixes missing typecheck module"
```

---

### Task 4: Ship-ready docs — CHANGELOG + DEFERRED

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/DEFERRED.md`

**Interfaces:** none (docs only). This task makes the merged branch tag-ready: the release
workflow extracts the `## [0.1.0]` CHANGELOG section into the GitHub Release notes, so it
must reflect the real feature set.

- [ ] **Step 1: Rewrite the `## [0.1.0]` CHANGELOG entry**

Replace the current `## [0.1.0]` section in `CHANGELOG.md` (keep the `# Changelog` header
and its "Keep a Changelog" line) with:

```markdown
## [0.1.0]
Initial release of Omelette — a small ML-family language that transpiles to readable Lua 5.1.

### Language
- Lexer, parser, resolver, codegen, compiler, CLI, and REPL.
- Immutable values; output reads like hand-written Lua.
- List comprehensions, `[a to b]` ranges, key/value generators, `xs[i]` indexing, `#xs` length.
- Pattern matching with variable/array/record destructuring and `when` guards.
- `if` and `match` as first-class expressions.
- Sum / variant types (capitalized constructors, `{ __tag = … }` runtime rep) with structural
  exhaustiveness checking, construction validation, and constructor-pattern validation.
- Optional, erased type annotations with an opt-in `omelette check`.

### Standard library
- `std.list`, `std.string`, `std.table` — bundled into the single-file binary, so
  `require("std.*")` resolves from any working directory.

### Tooling & docs
- `omelette run` / `build` / `check`, a `.egg` require-hook, and a single-file distributable binary.
- A runnable guide (`docs/guide.md`) whose every example is compiled and run in CI.
- A static site with a browser playground (runs the real compiler client-side) and syntax highlighting.
```

- [ ] **Step 2: Verify the release workflow can extract the section**

Run: `lua scripts/changelog.lua 0.1.0 < CHANGELOG.md | head -3`
Expected: prints the first lines of the 0.1.0 section (starting with "Initial release of
Omelette …"), exit 0 — proving the release step's `changelog.lua` extraction still matches.

- [ ] **Step 3: Update `docs/DEFERRED.md`**

Make three edits in `docs/DEFERRED.md`:

1. Bump the `_Last updated_` line to:

```markdown
_Last updated: 2026-08-24 (self-contained stdlib distribution: amalgam preload + LuaRocks command build)._
```

2. Replace the **"Stdlib distribution / discovery"** bullet (the one starting "the `.egg`
searcher resolves `require("std.*")` **relative to the CWD**") with a resolved marker:

```markdown
- **~~Stdlib distribution / discovery~~** — ✅ **DONE** (2026-08-24): `std/*.egg` is compiled
  to Lua at build time (`build/build-std.lua`) and embedded as `package.preload["std.*"]` in
  the single-file binary, so `require("std.*")` resolves from any cwd. The LuaRocks rock uses a
  command build that compiles std at install and ships every `omelette.*` module (fixing the
  previously-missing `omelette.typecheck`). _Source: 2026-08-24 stdlib-distribution spec._
```

3. Under **"Tooling & infrastructure"**, add a new deferred bullet for the untested rock path:

```markdown
- **End-to-end LuaRocks verification** — the rockspec's command build is validated
  structurally (it parses; install covers modules + std + bin) but not exercised via a real
  `luarocks build`/`install`, which is gated off while the repo is private. Verify in CI once
  the repo is public. _Source: 2026-08-24 stdlib-distribution spec._
```

- [ ] **Step 4: Run the full suite once more**

Run: `luajit spec/run.lua 2>&1 | tail -2`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md docs/DEFERRED.md
git commit -m "docs: 0.1.0 changelog + mark stdlib distribution done"
```

---

## Post-merge (owner / ship — not a plan task)

After this branch merges to `canon`: tag `v0.1.0` on `canon` → the release workflow validates
the tag against `init.lua` (already `0.1.0`), runs tests, builds + smoke-tests `dist/omelette`,
extracts the 0.1.0 CHANGELOG section, and cuts the GitHub Release. LuaRocks publish stays
skipped while the repo is private. Going public + setting `LUAROCKS_API_KEY` + enabling Pages
remain owner actions.
