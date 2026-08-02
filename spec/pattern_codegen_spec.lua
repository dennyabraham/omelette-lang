local h = require("spec.support.harness")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end

h.describe("pattern codegen", function()
  h.it("emits an IIFE with a subject temp and a no-match error", function()
    local out = gen("match v with | 0 -> 1 | _ -> 2")
    h.truthy(out:find("^%(function%(%)"))
    h.truthy(out:find("local __m1 = v"))
    h.truthy(out:find("if __m1 == 0 then"))
    h.truthy(out:find('error%("match: no matching case"%)'))
    h.truthy(out:find("end%)%(%)$"))
  end)

  h.it("behavioral: variable binding", function()
    local mod = assert(compiler.eval("pub let f v = match v with | n -> n * 2"))
    h.eq(mod.f(5), 10)
  end)
  h.it("behavioral: literal + wildcard (regression)", function()
    local mod = assert(compiler.eval('pub let f n = match n with | 0 -> "z" | 1 -> "o" | _ -> "m"'))
    h.eq(mod.f(0), "z"); h.eq(mod.f(1), "o"); h.eq(mod.f(7), "m")
  end)
  h.it("behavioral: array destructuring with length discrimination", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let f v = match v with",
      "  | [a] -> a",
      "  | [a, b] -> a + b",
      '  | _ -> 0',
    }, "\n")))
    h.eq(mod.f({ 7 }), 7)
    h.eq(mod.f({ 3, 4 }), 7)
    h.eq(mod.f({ 1, 2, 3 }), 0)
  end)
  h.it("behavioral: record pun and rename", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let f v = match v with | { x, y: b } -> x + b",
    }, "\n")))
    h.eq(mod.f({ x = 1, y = 2 }), 3)
  end)
  h.it("behavioral: nested pattern", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let f v = match v with | [a, [b, c]] -> a + b + c | _ -> 0",
    }, "\n")))
    h.eq(mod.f({ 1, { 2, 3 } }), 6)
    h.eq(mod.f({ 1, 2 }), 0)
  end)
  h.it("behavioral: guard matches or falls through", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let f n = match n with",
      '  | x when x > 10 -> "big"',
      '  | x when x > 0 -> "small"',
      '  | _ -> "other"',
    }, "\n")))
    h.eq(mod.f(20), "big"); h.eq(mod.f(3), "small"); h.eq(mod.f(-1), "other")
  end)
  h.it("behavioral: no-match raises", function()
    local mod = assert(compiler.eval('pub let f n = match n with | 0 -> "z"'))
    h.truthy(h.throws(function() mod.f(9) end))
  end)
  h.it("behavioral: match used as a call argument (first-class expression)", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let label n = tostring(match n with | 0 -> 0 | _ -> 1)",
    }, "\n")))
    h.eq(mod.label(0), "0"); h.eq(mod.label(5), "1")
  end)
end)
