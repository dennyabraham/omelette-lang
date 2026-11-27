local h = require("spec.support.harness")
local parser = require("omelette.parser")
local tc = require("omelette.typecheck")

local function diags(src) return (tc.check(assert(parser.parse(src)))) end

local function messages(src)
  local out = {}
  for i, d in ipairs(diags(src)) do out[i] = d.message end
  return out
end

-- The line and column of the first `needle` in src.
local function pos_of(src, needle)
  local i = assert(src:find(needle, 1, true))
  local line, col = 1, i
  for nl in src:sub(1, i - 1):gmatch("()\n") do line, col = line + 1, i - nl end
  return { line, col }
end

-- Expects exactly one diagnostic, with this message, at the first `at` in src.
local function one_error(src, message, at)
  local d = diags(src)
  h.eq(#d, 1)
  h.eq(d[1].message, message)
  h.eq({ d[1].line, d[1].col }, pos_of(src, at))
end

local function clean(src) h.eq(messages(src), {}) end

h.describe("branch checking against annotations", function()
  h.it("reports a wrong else branch at that branch", function()
    one_error('let f (x: number): number = if x > 0 then x else "neg"',
      "else branch is string, declared number", '"neg"')
  end)
  h.it("reports a wrong then branch at that branch", function()
    one_error('let f (x: number): number = if x > 0 then "pos" else x',
      "then branch is string, declared number", '"pos"')
  end)
  h.it("reports each wrong branch, and nothing at the let", function()
    h.eq(messages('let f (c: boolean): number = if c then "a" else "b"'),
      { "then branch is string, declared number", "else branch is string, declared number" })
  end)
  h.it("reports a wrong match arm", function()
    one_error('let m (v: number): number = match v with | 1 -> 1 | _ -> "x"',
      "match arm is string, declared number", '"x"')
  end)
  h.it("checks guarded arms, and reports other match errors once", function()
    one_error('let m (v: number): number = match v with | n when n > 1 -> "x" | _ -> 0',
      "match arm is string, declared number", '"x"')
    local src = 'type S = | A | B\nlet m (s: S): number = match s with | A -> "x"'
    local d = diags(src)
    h.eq(#d, 2)
    local branch, other = 0, 0
    for _, e in ipairs(d) do
      if e.message == "match arm is string, declared number" then branch = branch + 1 else other = other + 1 end
    end
    h.eq({ branch, other }, { 1, 1 })
  end)
  h.it("checks a value annotation", function()
    one_error('let c = true\nlet y: number = if c then 1 else "a"',
      "else branch is string, declared number", '"a"')
  end)
  h.it("reports the innermost branch", function()
    one_error('let f (a: boolean) (v: number): number = if a then (match v with | 1 -> 1 | _ -> "x") else 2',
      "match arm is string, declared number", '"x"')
    one_error('let f (c: boolean): number =\n  let a = 1\n  if c then a else "s"',
      "else branch is string, declared number", '"s"')
  end)
  h.it("reports a nil branch", function()
    one_error("let f (x: number): number = if x > 0 then x else nil",
      "else branch is nil, declared number", "nil")
  end)
  h.it("accepts a branch of type any", function()
    clean("let u x = x\nlet f (c: boolean): number = if c then u(1) else 2")
  end)
  h.it("accepts a recursive call in a branch", function()
    clean("let fact (n: number): number = if n == 0 then 1 else n * fact(n - 1)")
  end)
  h.it("accepts lambda branches against a function type", function()
    clean("let mk (b: boolean): (number) -> number = if b then fn x -> x else fn x -> x + 1")
  end)
  h.it("leaves unannotated branches that disagree alone", function()
    clean('let c = true\nlet y = if c then 1 else "a"')
    clean('let m v = match v with | 1 -> 1 | _ -> "x"')
  end)
  h.it("keeps the return message for a body with no if or match", function()
    one_error('let f (c: boolean): number =\n  let a = 1\n  "s"',
      "function 'f' returns string, declared number", "let f")
  end)
  h.it("reports an error inside a branch once", function()
    h.eq(messages('let f (c: boolean): number = if c then "a" + 1 else 2'),
      { "arithmetic '+' expects number, got string" })
  end)
end)

h.describe("branch checking against parameters", function()
  local G = "let g (n: number): number = n\n"
  h.it("reports a wrong branch passed to an annotated parameter", function()
    one_error(G .. 'let r (c: boolean) = g(if c then 1 else "a")',
      "else branch is string, argument 1 expects number", '"a"')
  end)
  h.it("checks a piped value as argument 1, and the call's own arguments after it", function()
    one_error(G .. 'let r (c: boolean) = (if c then 1 else "a") |> g',
      "else branch is string, argument 1 expects number", '"a"')
    one_error('let h (a: string) (n: number): number = n\nlet r (c: boolean) = "s" |> h(if c then 1 else "a")',
      "else branch is string, argument 2 expects number", '"a"')
  end)
  h.it("leaves a call with a hole or the wrong argument count to the existing checks", function()
    local ADD = "let add (x: number) (y: number): number = x + y\n"
    clean(ADD .. 'let r (c: boolean) = add(_, if c then 1 else "a")')
    h.eq(messages(ADD .. 'let r (c: boolean) = add(if c then 1 else "a")'),
      { "call expects 2 argument(s), got 1" })
  end)
  h.it("keeps the argument message for an argument that is not a branch", function()
    one_error(G .. 'let r = g("a")', "argument 1 expects number, got string", '"a"')
  end)
end)
