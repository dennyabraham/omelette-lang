local h = require("spec.support.harness")
local cli = require("omelette.cli")

-- capture stdout by swapping io.write
local function capture(fn)
  local buf = {}
  local real = io.write
  io.write = function(...) for _, v in ipairs({...}) do buf[#buf + 1] = tostring(v) end end
  local code = fn()
  io.write = real
  return code, table.concat(buf)
end

h.describe("cli", function()
  h.it("build prints compiled lua to stdout when no --out", function()
    local code, out = capture(function() return cli.main({ "build", "spec/fixtures/hello.egg" }) end)
    h.eq(code, 0)
    h.truthy(out:find("function M%.greet"))
  end)
  h.it("build --tokens dumps token types", function()
    local code, out = capture(function()
      return cli.main({ "build", "spec/fixtures/hello.egg", "--tokens" })
    end)
    h.eq(code, 0)
    h.truthy(out:find("keyword"))
  end)
  h.it("returns non-zero and prints a diagnostic on a bad file", function()
    local code, out = capture(function() return cli.main({ "build", "does/not/exist.egg" }) end)
    h.truthy(code ~= 0)
    h.truthy(out:find("error"))
  end)
  h.it("prints usage for unknown command", function()
    local code, out = capture(function() return cli.main({ "frobnicate" }) end)
    h.truthy(code ~= 0)
    h.truthy(out:find("usage"))
  end)
end)
