local h = require("spec.support.harness")
local compiler = require("omelette.compiler")

h.describe("top-level mutual recursion", function()
  h.it("mutually recursive functions work (is_even defined first)", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let is_even n = if n == 0 then true else is_odd(n - 1)",
      "pub let is_odd n = if n == 0 then false else is_even(n - 1)",
    }, "\n")))
    h.eq(mod.is_even(4), true)
    h.eq(mod.is_even(3), false)
    h.eq(mod.is_odd(3), true)
  end)
  h.it("mutually recursive functions work (is_odd defined first)", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let is_odd n = if n == 0 then false else is_even(n - 1)",
      "pub let is_even n = if n == 0 then true else is_odd(n - 1)",
    }, "\n")))
    h.eq(mod.is_even(4), true)
    h.eq(mod.is_odd(3), true)
  end)
  h.it("a function may call a sibling defined below it (forward reference)", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let outer x = inner(x) + 1",
      "let inner x = x * 2",
    }, "\n")))
    h.eq(mod.outer(5), 11)
  end)
end)
