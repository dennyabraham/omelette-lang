local h = require("spec.support.harness")
local parser = require("omelette.parser")
local function prog(s) return assert(parser.parse(s)) end
local function ex(s) return assert(parser.parse_expr_string(s)) end

h.describe("positional constructors — parsing", function()
  h.it("declares a positional variant with an arity", function()
    local td = prog("type Option = Some(a) | None").stmts[1]
    h.eq(td.variants[1].name, "Some")
    h.truthy(td.variants[1].positional)
    h.eq(td.variants[1].arity, 1)
    h.truthy(td.variants[2].positional == nil)   -- None is nullary
  end)
  h.it("declares a 2-arity positional variant", function()
    local td = prog("type Tree = Leaf(v) | Node(l, r)").stmts[1]
    h.eq(td.variants[2].arity, 2)
  end)
  h.it("parses positional construction `Some(3)`", function()
    local e = ex("Some(3)")
    h.eq(e.kind, "construct")
    h.truthy(e.positional)
    h.eq(#e.args, 1)
    h.eq(e.args[1].kind, "number")
  end)
  h.it("named construction still parses", function()
    local e = ex("Circle { radius = 3 }")
    h.eq(e.kind, "construct")
    h.truthy(e.positional == nil)
    h.eq(e.fields[1].key, "radius")
  end)
  h.it("parses a positional constructor pattern", function()
    local node = prog("let f x = match x with | Some(v) -> v | None -> 0").stmts[1]
    -- dig to the match's first case pattern
    local m = node.value
    h.eq(m.cases[1].pattern.kind, "ctor_pat")
    h.truthy(m.cases[1].pattern.positional)
    h.eq(#m.cases[1].pattern.args, 1)
  end)
end)
