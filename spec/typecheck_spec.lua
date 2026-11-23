local h = require("spec.support.harness")
local parser = require("omelette.parser")
local tc = require("omelette.typecheck")
local function diags(s) return tc.check(assert(parser.parse(s))) end
local function ok(s) h.eq(#diags(s), 0) end
local function bad(s, needle)
  local d = diags(s)
  h.truthy(#d >= 1)
  h.truthy(d[1].message:find(needle, 1, true))
end

h.describe("typecheck", function()
  h.it("clean annotated program has no diagnostics", function()
    ok("pub let add (x: number) (y: number): number = x + y")
    ok('pub let greet (name: string): string = "hi " .. name')
    ok("let count: number = 0")
  end)
  h.it("value binding mismatch", function()
    bad('let x: number = "hi"', "number")
  end)
  h.it("function return mismatch", function()
    bad('let f (x: number): number = x .. "!"', "returns")
  end)
  h.it("arithmetic on a string operand", function()
    bad("let f (s: string): number = s + 1", "number")
  end)
  h.it("concat on a number operand", function()
    bad('let f (n: number): string = n .. "x"', "string")
  end)
  h.it("call argument mismatch against an annotated function", function()
    bad(table.concat({
      "let add (x: number) (y: number): number = x + y",
      'let bad = add(1, "x")',
    }, "\n"), "argument 2")
  end)
  h.it("names a function type by its signature", function()
    bad(table.concat({
      "let apply (f: (number) -> number) (x: number): number = f(x)",
      "let show (n: number): string = \"\"",
      "let bad = apply(show, 1)",
    }, "\n"), "argument 1 expects (number) -> number, got (number) -> string")
    bad("let f (g: (string) -> string): number = g", "returns (string) -> string, declared number")
  end)
  h.it("call arity mismatch", function()
    bad(table.concat({
      "let add (x: number) (y: number): number = x + y",
      "let bad = add(1)",
    }, "\n"), "argument")
  end)
  h.it("any / unannotated / interop never error", function()
    ok("let f x y = x + y")                                   -- untyped params are any
    ok('let r = vim.api.foo(1, "x", true)')                   -- Lua interop is any
    ok(table.concat({
      "let g x = x",                                          -- unannotated fn -> any-typed
      'let r = g("anything")',
    }, "\n"))
  end)
  h.it("clean program with a partial-application hole is not arg-checked", function()
    ok(table.concat({
      "let add (x: number) (y: number): number = x + y",
      "let inc = add(1, _)",
    }, "\n"))
  end)
end)
