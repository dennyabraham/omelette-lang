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
  h.it("bundles typecheck so the single-file CLI can `check`", function()
    h.truthy(amalg.build():find('package.preload%["omelette.typecheck"%]'))
  end)
  h.it("os.exit()s with the CLI status (a bare `return` would always exit 0)", function()
    local out = amalg.build()
    h.truthy(out:find('os%.exit%(require%("omelette.cli"%)%.main%(arg%)%)'))
    h.truthy(not out:find('return require%("omelette.cli"%)%.main'))
  end)
  h.it("the amalgamated binary type-checks (no filesystem) and exits non-zero on errors", function()
    -- write the single-file binary + programs into a temp dir with NO ./omelette/*.lua,
    -- then run it there — a passing `check` proves typecheck is bundled (not loaded from
    -- disk), exactly like an installed single-file omelette; `; echo EXIT=$?` captures the
    -- process exit code portably (LuaJIT's io.popen:close does not return it).
    local dir = os.tmpname() .. "_d"
    os.execute('mkdir -p "' .. dir .. '"')
    local function put(name, data) local f = assert(io.open(dir .. "/" .. name, "w")); f:write(data); f:close() end
    put("omelette", amalg.build())
    put("bad.egg", 'let x: number = "hi"\n')
    put("ok.egg", 'pub let add (x: number) (y: number): number = x + y\n')
    local interp = (arg and arg[-1]) or "lua"   -- luajit locally; `lua` on both CI legs
    local function run(f)
      local p = io.popen('cd "' .. dir .. '" && "' .. interp .. '" omelette check ' .. f .. ' 2>&1; echo EXIT=$?')
      local out = p:read("*a"); p:close(); return out
    end
    local bad = run("bad.egg")
    h.truthy(bad:find("number", 1, true))          -- the type diagnostic from bundled typecheck
    h.truthy(not bad:find("not found", 1, true))   -- NOT a missing-module crash
    h.truthy(bad:find("EXIT=1", 1, true))          -- non-zero exit on a type error
    h.truthy(run("ok.egg"):find("EXIT=0", 1, true))  -- clean program exits 0
    os.execute('rm -rf "' .. dir .. '"')
  end)
end)
