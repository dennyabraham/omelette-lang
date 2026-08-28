local h = require("spec.support.harness")
local compiler = require("omelette.compiler")
-- opts.check = true runs the checker; compile returns nil,err on a diagnostic
local function check(src) return compiler.compile(src, { check = true }) end

h.describe("positional constructors — checking", function()
  h.it("accepts a correct-arity construction and match", function()
    local ok = check([[
type Option = Some(a) | None
let f o = match o with | Some(x) -> x | None -> 0
pub let r = f(Some(1))
]])
    h.truthy(ok)
  end)
  h.it("rejects wrong-arity construction", function()
    local ok, err = check("type Pair = Pair(a, b)\npub let v = Pair(1)")
    h.truthy(not ok)
    h.truthy(err.message:find("argument", 1, true))
  end)
  h.it("rejects wrong-arity pattern", function()
    local ok, err = check([[
type Pair = Pair(a, b)
let f p = match p with | Pair(x) -> x
pub let r = f(Pair(1, 2))
]])
    h.truthy(not ok)
    h.truthy(err.message:find("argument", 1, true))
  end)
  h.it("rejects named syntax on a positional constructor", function()
    local ok, err = check("type Option = Some(a) | None\npub let v = Some { a = 1 }")
    h.truthy(not ok)
    h.truthy(err.message:find("positional", 1, true))
  end)
  h.it("rejects positional syntax on a named constructor", function()
    local ok, err = check("type Shape = Circle { radius }\npub let v = Circle(3)")
    h.truthy(not ok)
    h.truthy(err.message:find("named", 1, true))
  end)
  h.it("checks exhaustiveness over positional constructors", function()
    local ok, err = check([[
type Option = Some(a) | None
let f o = match o with | Some(x) -> x
pub let r = f(Some(1))
]])
    h.truthy(not ok)
    h.truthy(err.message:find("exhaustive", 1, true))
  end)
end)
