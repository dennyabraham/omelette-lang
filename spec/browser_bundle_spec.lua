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

  -- Assert on a distinct RESULT= sentinel, NOT a bare digit: a require failure
  -- crashes the fresh VM and its traceback (line numbers, addresses) incidentally
  -- contains digits, so `out:find("3")` would pass even on a broken bundle. The
  -- sentinel is only printed when the compiler actually ran, and never appears in a
  -- traceback — so a module missing from the bundle makes these tests fail.
  h.it("preloads the compiler and runs code with no filesystem", function()
    local out = run_fresh(bundle,
      'require("omelette.compiler").eval([==[print("RESULT=" .. (1 + 2))]==])')
    h.truthy(out:find("RESULT=3", 1, true))
    h.truthy(not out:find("not found", 1, true))
  end)
  h.it("resolves the embedded stdlib via require (no ./std on disk)", function()
    local out = run_fresh(bundle,
      'require("omelette.compiler").eval([==[let l = require("std.list") print("RESULT=" .. l.sum([1, 2, 3]))]==])')
    h.truthy(out:find("RESULT=6", 1, true))
    h.truthy(not out:find("not found", 1, true))
  end)
  h.it("bundles typecheck so check() works", function()
    local out = run_fresh(bundle,
      'local d = require("omelette.compiler").check([==[let x: number = "hi"]==]); print("RESULT=" .. #d)')
    h.truthy(out:find("RESULT=1", 1, true))
    h.truthy(not out:find("not found", 1, true))
  end)
  h.it("does not auto-run the CLI", function()
    h.truthy(not bundle:find("cli"))
    h.truthy(not bundle:find("%.main%("))
  end)
end)
