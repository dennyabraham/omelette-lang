local h = require("spec.support.harness")
local lexer = require("omelette.lexer")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function expr(s) return assert(parser.parse_expr_string(s)) end
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end

h.describe("dict comprehensions", function()
  h.it("lexes => as one op token", function()
    local toks = assert(lexer.tokenize("k => v"))
    h.eq(toks[2], { type = "op", value = "=>", line = 1, col = 3 })
  end)
  h.it("still lexes record `=` (not =>)", function()
    local toks = assert(lexer.tokenize("x = 1"))
    h.eq(toks[2], { type = "op", value = "=", line = 1, col = 3 })
  end)
  h.it("parses a dict comprehension", function()
    local e = expr("{ k => v | k, v <- d }")
    h.eq(e.kind, "dict_comprehension")
    h.eq(e.key.name, "k")
    h.eq(e.value.name, "v")
    h.eq(#e.quals, 1)
    h.eq(e.quals[1].kind, "generator")
    h.eq(e.quals[1].value_name, "v")
  end)
  h.it("still parses record literals (regression)", function()
    h.eq(expr("{ x = 1, y = 2 }").kind, "table")
    h.eq(expr("{}").kind, "table")
    h.eq(#expr("{}").fields, 0)
  end)
  h.it("emits an IIFE assigning acc[key] = value", function()
    h.eq(gen("{ k => v | k, v <- d }"),
      "(function()\n  local __acc1 = {}\n  for k, v in pairs(d) do\n"
      .. "    __acc1[k] = v\n  end\n  return __acc1\nend)()")
  end)
  h.it("behavioral: copy, map values, filter, and build-from-range", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let copy = { k => v | k, v <- { a = 1, b = 2 } }",
      "pub let scaled = { k => v * 10 | k, v <- { a = 1, b = 2 } }",
      "pub let big = { k => v | k, v <- { a = 1, b = 2, c = 3 }, v > 1 }",
      "pub let squares = { i => i * i | i <- [1 to 3] }",
    }, "\n")))
    h.eq(mod.copy, { a = 1, b = 2 })
    h.eq(mod.scaled, { a = 10, b = 20 })
    h.eq(mod.big, { b = 2, c = 3 })
    h.eq(mod.squares, { 1, 4, 9 })
  end)
  h.it("behavioral: nests a list comprehension inside a dict comprehension (distinct __acc gensyms)", function()
    -- inner list-comp uses __acc2 while the outer dict-comp uses __acc1; must not collide
    local mod = assert(compiler.eval(
      "pub let g = { k => [ x * 2 | x <- v ] | k, v <- { a = [1, 2], b = [3] } }"))
    h.eq(mod.g, { a = { 2, 4 }, b = { 6 } })
  end)
end)
