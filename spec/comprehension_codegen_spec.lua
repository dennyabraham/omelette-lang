local h = require("spec.support.harness")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local function gen(s)
  local e = assert(parser.parse_expr_string(s))
  return codegen.expr(e, codegen.new_ctx())
end

h.describe("codegen/comprehension", function()
  h.it("emits an IIFE for a single generator", function()
    h.eq(gen("[ x * 2 | x <- nums ]"),
      "(function()\n  local __acc1 = {}\n  for _, x in ipairs(nums) do\n"
      .. "    __acc1[#__acc1 + 1] = (x * 2)\n  end\n  return __acc1\nend)()")
  end)
  h.it("emits a guard as a nested if", function()
    h.eq(gen("[ x | x <- nums, even(x) ]"),
      "(function()\n  local __acc1 = {}\n  for _, x in ipairs(nums) do\n"
      .. "    if even(x) then\n      __acc1[#__acc1 + 1] = x\n    end\n  end\n"
      .. "  return __acc1\nend)()")
  end)
  h.it("nests multiple generators with an interleaved guard", function()
    h.eq(gen("[ [x, y] | x <- xs, x > 0, y <- ys ]"),
      "(function()\n  local __acc1 = {}\n  for _, x in ipairs(xs) do\n"
      .. "    if (x > 0) then\n      for _, y in ipairs(ys) do\n"
      .. "        __acc1[#__acc1 + 1] = {x, y}\n      end\n    end\n  end\n"
      .. "  return __acc1\nend)()")
  end)
end)
