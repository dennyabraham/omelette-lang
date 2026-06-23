local h = require("spec.support.harness")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function expr(s) return assert(parser.parse_expr_string(s)) end
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end

h.describe("key/value comprehension generators", function()
  h.it("parses a two-name generator", function()
    local e = expr("[ k | k, v <- d ]")
    h.eq(e.kind, "comprehension")
    h.eq(e.quals[1].kind, "generator")
    h.eq(e.quals[1].name, "k")
    h.eq(e.quals[1].value_name, "v")
    h.eq(e.quals[1].source.name, "d")
  end)
  h.it("leaves single-name generators with value_name = nil", function()
    local e = expr("[ x | x <- xs ]")
    h.eq(e.quals[1].name, "x")
    h.eq(e.quals[1].value_name, nil)
  end)
  h.it("emits pairs(...) for two names and ipairs(...) for one", function()
    h.truthy(gen("[ k | k, v <- d ]"):find("for k, v in pairs%(d%) do"))
    h.truthy(gen("[ x | x <- xs ]"):find("for _, x in ipairs%(xs%) do"))
  end)
  h.it("behavioral: keys and values of a record", function()
    local mod = assert(compiler.eval(table.concat({
      'pub let ks = [ k | k, v <- { a = 1, b = 2 } ]',
      'pub let vs = [ v | k, v <- { a = 1, b = 2 } ]',
    }, "\n")))
    table.sort(mod.ks)
    table.sort(mod.vs)
    h.eq(mod.ks, { "a", "b" })   -- pairs order is unspecified; sort to compare
    h.eq(mod.vs, { 1, 2 })
  end)
end)
