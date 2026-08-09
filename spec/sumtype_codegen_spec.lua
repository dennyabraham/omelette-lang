local h = require("spec.support.harness")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end
local function prog(s) return codegen.program(assert(parser.parse(s))) end

h.describe("sum type codegen", function()
  h.it("emits a tagged table for construction", function()
    h.eq(gen("Circle { radius = 5 }"), '{ __tag = "Circle", radius = 5 }')
    h.eq(gen("None"), '{ __tag = "None" }')
  end)
  h.it("emits nothing for a type declaration (erased)", function()
    local out = prog("type Shape = | Circle { radius } | Origin")
    h.truthy(not out:find("Shape"))
    h.truthy(not out:find("__tag"))    -- decl alone emits no runtime code
    h.truthy(out:find("local M = {}"))
  end)
  h.it("a constructor pattern tests type + __tag", function()
    local out = gen("match v with | Some { value } -> value | None -> 0")
    -- the match subject is bound once to a fresh local (__m1), not referenced by
    -- its original name (see pattern_codegen_spec.lua / codegen_module_spec.lua),
    -- so the __tag test is against that local, not "v" directly.
    h.truthy(out:find('__tag == "Some"'))
    h.truthy(out:find('__tag == "None"'))
  end)

  h.it("behavioral: Option round-trips", function()
    local mod = assert(compiler.eval(table.concat({
      "pub type Option = | Some { value } | None",
      "pub let unwrap opt fb = match opt with | Some { value } -> value | None -> fb",
      "pub let mk x = Some { value = x }",
      "pub let none = None",
    }, "\n")))
    h.eq(mod.unwrap(mod.mk(42), 0), 42)
    h.eq(mod.unwrap(mod.none, -1), -1)
  end)
  h.it("behavioral: Shape dispatch", function()
    local mod = assert(compiler.eval(table.concat({
      "type Shape = | Circle { radius } | Rect { width, height } | Origin",
      "pub let area s = match s with",
      "  | Circle { radius }       -> 3 * radius * radius",
      "  | Rect { width, height }  -> width * height",
      "  | Origin                  -> 0",
      "pub let c = Circle { radius = 2 }",
      "pub let r = Rect { width = 4, height = 3 }",
      "pub let o = Origin",
    }, "\n")))
    h.eq(mod.area(mod.c), 12); h.eq(mod.area(mod.r), 12); h.eq(mod.area(mod.o), 0)
  end)
  h.it("behavioral: recursive tree sum", function()
    local mod = assert(compiler.eval(table.concat({
      "type Tree = | Node { left, value, right } | Leaf",
      "pub let sum t = match t with",
      "  | Leaf -> 0",
      "  | Node { left, value, right } -> sum(left) + value + sum(right)",
      "pub let make = Node { left = Node { left = Leaf, value = 1, right = Leaf }, value = 2, right = Leaf }",
    }, "\n")))
    h.eq(mod.sum(mod.make), 3)
  end)
  h.it("behavioral: nested constructor pattern + guard", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let f v = match v with",
      "  | Some { value: [a, b] } when a > b -> a",
      "  | Some { value: [a, b] }            -> b",
      "  | _                                 -> 0",
    }, "\n")))
    h.eq(mod.f({ __tag = "Some", value = { 5, 2 } }), 5)
    h.eq(mod.f({ __tag = "Some", value = { 1, 9 } }), 9)
    h.eq(mod.f({ __tag = "None" }), 0)
  end)
  h.it("behavioral: __tag does not clash with a user field named tag", function()
    local mod = assert(compiler.eval(table.concat({
      "pub let mk = Circle { tag = 9, radius = 1 }",
      "pub let r v = match v with | Circle { tag, radius } -> tag + radius | _ -> 0",
    }, "\n")))
    h.eq(mod.r(mod.mk), 10)
  end)
  h.it("indexing a construct literal is parenthesized (Lua 5.1)", function()
    -- Some { value = 7 }["value"] must emit ({...})["value"], not {...}["value"] (unloadable)
    h.eq(gen('Some { value = 7 }["value"]'), '({ __tag = "Some", value = 7 })["value"]')
    local mod = assert(compiler.eval('pub let x = Some { value = 7 }["value"]'))
    h.eq(mod.x, 7)
  end)
  h.it("call syntax on a constructor gives a friendly error", function()
    local lua, err = compiler.compile("pub let x = Some(5)")
    h.truthy(lua == nil)
    h.truthy(err.message:find("braces"))
    h.truthy(err.message:find("Some"))
  end)
  h.it("a __tag field in construction is rejected", function()
    local lua, err = compiler.compile("pub let x = Circle { __tag = 9 }")
    h.truthy(lua == nil)
    h.truthy(err.message:find("__tag"))
    h.truthy(err.message:find("reserved"))
  end)
end)
