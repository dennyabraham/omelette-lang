local h = require("spec.support.harness")
local parser = require("omelette.parser")
local tc = require("omelette.typecheck")
local function diags(s) return tc.check(assert(parser.parse(s))) end

h.describe("sum type typecheck", function()
  h.it("no false positives for decls + construction + constructor patterns", function()
    h.eq(#diags(table.concat({
      "type Option = | Some { value } | None",
      "pub let unwrap opt fb = match opt with | Some { value } -> value | None -> fb",
      "pub let mk x = Some { value = x }",
    }, "\n")), 0)
  end)
  h.it("still catches a real mismatch elsewhere", function()
    local d = diags(table.concat({
      "type Option = | Some { value } | None",
      'let bad: number = "hi"',
    }, "\n"))
    h.truthy(#d >= 1)
    h.truthy(d[1].message:find("number", 1, true))
  end)
  h.it("walks construct field values (an error inside a field is caught)", function()
    local d = diags('let x = Some { value = 1 + "oops" }')
    h.truthy(#d >= 1)
  end)
end)
