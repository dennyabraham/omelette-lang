local h = require("spec.support.harness")
local compiler = require("omelette.compiler")

-- Lua 5.1 rejects a literal as the base of an index/field/call without parens
-- (`{..}[k]`, `{..}.f`, `(fn..)(x)`). Codegen wraps those bases in parens; these
-- prove the emitted Lua both loads and runs.
h.describe("literal-base wrapping (index / field / call)", function()
  local function val(src, name)
    local mod = assert(compiler.eval(src))
    return mod[name]
  end

  h.it("field access on a construct literal", function()
    h.eq(val("pub let r = Circle { radius = 5 }.radius", "r"), 5)
  end)
  h.it("field access on a table literal", function()
    h.eq(val("pub let x = ({ a = 1 }).a", "x"), 1)
  end)
  h.it("indexing an array literal", function()
    h.eq(val("pub let y = [10, 20, 30][2]", "y"), 20)
  end)
  h.it("calling a lambda literal", function()
    h.eq(val("pub let z = (fn n -> n + 1)(5)", "z"), 6)
  end)
  h.it("a lambda-literal call composes in a larger expression", function()
    h.eq(val("pub let w = (fn n -> n * 2)(3) + 1", "w"), 7)
  end)
  h.it("the emitted Lua actually loads (no syntax error)", function()
    local lua = assert(compiler.compile(
      "pub let a = ({ k = 9 }).k\npub let b = (fn n -> n)(1)\npub let c = [1, 2][1]"))
    local load_fn = loadstring or load
    h.truthy((load_fn(lua)))
  end)
end)
