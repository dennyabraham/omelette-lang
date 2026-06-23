local h = require("spec.support.harness")
local parser = require("omelette.parser")
local codegen = require("omelette.codegen")
local compiler = require("omelette.compiler")
local function expr(s) return assert(parser.parse_expr_string(s)) end
local function gen(s) return codegen.expr(assert(parser.parse_expr_string(s)), codegen.new_ctx()) end

h.describe("read indexing", function()
  h.it("parses xs[i] as an index node", function()
    local e = expr("xs[1]")
    h.eq(e.kind, "index")
    h.eq(e.obj.name, "xs")
    h.eq(e.key.value, 1)
  end)
  h.it("nests chained indexing grid[i][j]", function()
    local e = expr("grid[i][j]")
    h.eq(e.kind, "index")
    h.eq(e.key.name, "j")
    h.eq(e.obj.kind, "index")
    h.eq(e.obj.key.name, "i")
  end)
  h.it("still parses a bare array literal in primary position", function()
    h.eq(expr("[1, 2, 3]").kind, "array")
  end)
  h.it("rejects a two-key index", function()
    local _, err = parser.parse_expr_string("xs[1, 2]")
    h.truthy(err ~= nil)
  end)
  h.it("emits obj[key]", function()
    h.eq(gen("xs[1]"), "xs[1]")
    h.eq(gen('record["key"]'), 'record["key"]')
  end)
  h.it("behavioral: index into an array and a record", function()
    local mod = assert(compiler.eval('pub let a = [10, 20, 30][2]\npub let b = { x = 1, y = 2 }["y"]'))
    h.eq(mod.a, 20)
    h.eq(mod.b, 2)
  end)
  h.it("behavioral: indexing + length enable a tail-recursive fold", function()
    local mod = assert(compiler.eval(table.concat({
      "let sum_go xs acc i =",
      "  if i > #xs then acc",
      "  else sum_go(xs, acc + xs[i], i + 1)",
      "pub let sum xs = sum_go(xs, 0, 1)",
    }, "\n")))
    h.eq(mod.sum({ 3, 4, 5 }), 12)
    h.eq(mod.sum({}), 0)
  end)
  h.it("parenthesizes constructor and string-literal objects (Lua 5.1 requires it)", function()
    h.eq(gen("[1, 2, 3][2]"), "({1, 2, 3})[2]")
    h.eq(gen('{ x = 1 }["x"]'), '({x = 1})["x"]')
    h.eq(gen('"abc"[1]'), '("abc")[1]')
  end)
  h.it("does NOT parenthesize non-literal objects", function()
    h.eq(gen("xs[1]"), "xs[1]")
    h.eq(gen("f(x)[1]"), "f(x)[1]")
  end)
  h.it("behavioral: indexing a string literal yields nil (string indexing is unsupported, returns nil not an error)", function()
    local mod = assert(compiler.eval('pub let r = "abc"[1]'))
    h.eq(mod.r, nil)
  end)
  h.it("parses #xs[i] as #(xs[i])", function()
    local e = assert(parser.parse_expr_string("#xs[i]"))
    h.eq(e.kind, "unop"); h.eq(e.op, "#")
    h.eq(e.operand.kind, "index")
  end)
  h.it("parenthesizes a lambda-literal index object (Lua 5.1; surface-unreachable, codegen-level)", function()
    -- the parser can't put a bare `fn` in object position, so build the AST directly
    local node = {
      kind = "index",
      obj = { kind = "lambda", params = { "x" }, body = { kind = "ident", name = "x" } },
      key = { kind = "number", value = 1 },
    }
    local out = codegen.expr(node, codegen.new_ctx())
    h.truthy(out:sub(1, 1) == "(")            -- wrapped, not bare `function...end[1]`
    h.truthy(out:find("%)%[1%]") ~= nil)      -- closes with )[1]
  end)
end)
