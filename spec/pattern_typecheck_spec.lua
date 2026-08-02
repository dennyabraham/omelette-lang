local h = require("spec.support.harness")
local parser = require("omelette.parser")
local tc = require("omelette.typecheck")
local function diags(s) return tc.check(assert(parser.parse(s))) end

h.describe("pattern typecheck", function()
  h.it("no false positives for bindings + destructuring + guards", function()
    h.eq(#diags(table.concat({
      "pub let f v = match v with",
      "  | [a, b] -> a + b",
      "  | { x, y: c } -> x + c",
      '  | n when n > 0 -> n',
      "  | _ -> 0",
    }, "\n")), 0)
  end)
  h.it("a real mismatch elsewhere is still caught", function()
    local d = diags(table.concat({
      "let g v = match v with | n -> n",   -- fine
      'let bad: number = "hi"',             -- real error
    }, "\n"))
    h.truthy(#d >= 1)
    h.truthy(d[1].message:find("number", 1, true))
  end)
end)
