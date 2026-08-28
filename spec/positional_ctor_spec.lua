local h = require("spec.support.harness")
local compiler = require("omelette.compiler")
local function eval(src) return assert(compiler.eval(src)) end

h.describe("positional constructors — runtime", function()
  h.it("builds and matches a 1-arity positional constructor", function()
    h.eq(eval([[
type Option = Some(a) | None
let unwrap o = match o with | Some(x) -> x | None -> 0
pub let r = unwrap(Some(7))
]]).r, 7)
  end)
  h.it("builds and matches a 2-arity positional constructor", function()
    h.eq(eval([[
type Pair = Pair(a, b)
let sum p = match p with | Pair(x, y) -> x + y
pub let r = sum(Pair(3, 4))
]]).r, 7)
  end)
  h.it("a wildcard ignores a positional slot", function()
    h.eq(eval([[
type Pair = Pair(a, b)
pub let r = match Pair(3, 4) with | Pair(_, y) -> y
]]).r, 4)
  end)
  h.it("nullary and positional coexist; None matches", function()
    h.eq(eval([[
type Option = Some(a) | None
pub let r = match None with | Some(x) -> x | None -> 99
]]).r, 99)
  end)
  h.it("the runtime rep puts the payload in the array part with __tag", function()
    local m = eval([[
type Option = Some(a) | None
pub let v = Some(5)
]])
    h.eq(m.v.__tag, "Some")
    h.eq(m.v[1], 5)
  end)
  h.it("positional and named constructors in one type both work", function()
    h.eq(eval([[
type Shape = Dot(x) | Circle { radius }
let area s = match s with | Dot(_) -> 0 | Circle { radius } -> radius * radius
pub let r = area(Circle { radius = 3 }) + area(Dot(9))
]]).r, 9)
  end)
  h.it("the emitted Lua loads", function()
    local lua = assert(compiler.compile("type T = A(x)\npub let v = A(1)"))
    local load_fn = loadstring or load
    h.truthy((load_fn(lua)))
  end)
end)
