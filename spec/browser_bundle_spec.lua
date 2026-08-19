local h = require("spec.support.harness")
local site = require("site.build")

-- run a driver in a FRESH luajit with package.path/cpath ZEROED after loading the
-- bundle — so require resolves ONLY through the bundle's package.preload + embedded-std
-- searcher, with NO filesystem fallback. This is the same isolation Fengari has in the
-- browser: a module missing from the bundle fails here (it can't silently load from ./).
local function run_fresh(bundle, driver_body)
  local tmpb, tmpd = os.tmpname(), os.tmpname() .. ".lua"
  local fb = io.open(tmpb, "w"); fb:write(bundle); fb:close()
  local fd = io.open(tmpd, "w")
  fd:write('dofile("' .. tmpb .. '")\npackage.path = ""; package.cpath = ""\n' .. driver_body)
  fd:close()
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
