local h = require("spec.support.harness")
local parser = require("omelette.parser")
local typecheck = require("omelette.typecheck")

local function check(src)
  local _, binding_of, type_of = typecheck.check(assert(parser.parse(src)))
  return binding_of, type_of
end

-- The node of the given kind that binding_of (or type_of) has as a key, starting at line:col.
local function key_at(t, line, col, kind)
  for node in pairs(t) do
    if node.start_line == line and node.start_col == col and (not kind or node.kind == kind) then
      return node
    end
  end
end

local function decl_at(src, line, col)
  local b = check(src)
  local k = key_at(b, line, col)
  return k and b[k]
end

local function span(d) return { d.line, d.col, d.end_line, d.end_col } end

h.describe("bindings", function()
  h.it("binds a parameter use to the parameter", function()
    local d = decl_at("let f x = x", 1, 11)
    h.eq(d.kind, "parameter")
    h.eq(span(d), { 1, 7, 1, 8 })
  end)
  h.it("binds a shadowing lambda parameter, not the outer name", function()
    local d = decl_at("let x = 1\nlet g = fn x -> x", 2, 17)
    h.eq(d.kind, "parameter")
    h.eq(span(d), { 2, 12, 2, 13 })
  end)
  h.it("binds a match arm's pattern variable", function()
    local d = decl_at("let m v = match v with | { y } -> y", 1, 35)
    h.eq(d.kind, "variable")
    h.eq(span(d), { 1, 28, 1, 29 })
  end)
  h.it("binds comprehension variables", function()
    local d = decl_at("let ys xs = [ x * 2 | x <- xs ]", 1, 15)
    h.eq(span(d), { 1, 23, 1, 24 })
    local v = decl_at("let m t = { k => v | k, v <- t }", 1, 18)
    h.eq(span(v), { 1, 25, 1, 26 })
  end)
  h.it("binds mutually recursive top-level functions", function()
    local d = decl_at("let even n = if n == 0 then true else odd(n - 1)\n"
      .. "let odd n = if n == 0 then false else even(n - 1)", 1, 39)
    h.eq(d.kind, "function")
    h.eq(span(d), { 2, 5, 2, 8 })
  end)
  h.it("binds a destructured name", function()
    local d = decl_at("let (a, b) = (1, 2)\nlet c = a", 2, 9)
    h.eq(d.kind, "variable")
    h.eq(span(d), { 1, 6, 1, 7 })
  end)
  h.it("binds constructors and type names to their declaration", function()
    local src = "type Shape = | Circle { r } | Dot\n"
      .. "let area (s : Shape) = match s with | Circle { r } -> r | Dot -> 0\n"
      .. "let d = Dot"
    local b = check(src)
    local dot = b[key_at(b, 3, 9, "construct")]
    h.eq(dot.kind, "enumMember")
    h.eq(dot.node.kind, "type_decl")
    h.eq(span(dot), { 1, 31, 1, 34 })
    local circle = b[key_at(b, 2, 39, "ctor_pat")]
    h.eq(circle.kind, "enumMember")
    h.eq(span(circle), { 1, 16, 1, 22 })
    local shape = b[key_at(b, 2, 15, "type_name")]
    h.eq(shape.kind, "type")
    h.eq(span(shape), { 1, 6, 1, 11 })
  end)
  h.it("leaves a Lua global unbound", function()
    h.eq(decl_at("let p = print(1)", 1, 9), nil)
  end)
  h.it("records the type of a use", function()
    local _, type_of = check("let n : number = 1\nlet m = n")
    h.eq(type_of[key_at(type_of, 2, 9, "ident")], { kind = "number" })
  end)
end)

h.describe("format_type", function()
  local N, S, B = { kind = "number" }, { kind = "string" }, { kind = "boolean" }
  local function fun(params, ret) return { kind = "fun", params = params, ret = ret } end
  h.it("prints primitive types by their kind", function()
    for _, k in ipairs({ "number", "string", "boolean", "nil", "any" }) do
      h.eq(typecheck.format_type({ kind = k }), k)
    end
  end)
  h.it("prints function types with their parameters in parentheses", function()
    h.eq(typecheck.format_type(fun({}, { kind = "any" })), "() -> any")
    h.eq(typecheck.format_type(fun({ N }, N)), "(number) -> number")
    h.eq(typecheck.format_type(fun({ N, S }, B)), "(number, string) -> boolean")
    h.eq(typecheck.format_type(fun({ fun({ N }, N) }, N)), "((number) -> number) -> number")
  end)
end)
