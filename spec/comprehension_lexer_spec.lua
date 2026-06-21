local h = require("spec.support.harness")
local lexer = require("omelette.lexer")

local function types_and_values(src)
  local toks = assert(lexer.tokenize(src))
  local out = {}
  for _, t in ipairs(toks) do out[#out + 1] = { t.type, t.value } end
  return out
end

h.describe("lexer/arrow", function()
  h.it("lexes <- as a single op token", function()
    local toks = assert(lexer.tokenize("x <- xs"))
    h.eq(toks[1], { type = "ident", value = "x", line = 1, col = 1 })
    h.eq(toks[2], { type = "op", value = "<-", line = 1, col = 3 })
    h.eq(toks[3].value, "xs")
  end)
  h.it("lexes adjacent x<-1 greedily as the binder, not less-than-negative", function()
    local toks = assert(lexer.tokenize("x<-1"))
    h.eq(toks[2], { type = "op", value = "<-", line = 1, col = 2 })
  end)
  h.it("keeps spaced x < -1 as three tokens", function()
    h.eq(types_and_values("x < -1"),
      { { "ident", "x" }, { "op", "<" }, { "op", "-" }, { "number", 1 }, { "eof", "<eof>" } })
  end)
end)
