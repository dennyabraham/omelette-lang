local h = require("spec.support.harness")
local parser = require("omelette.parser")
local position = require("omelette.lsp.position")
local tokens = require("omelette.lsp.tokens")

local TYPES = tokens.LEGEND.tokenTypes

-- Decodes LSP relative token data into absolute { line, char, len, type, decl } rows.
local function rows(source, encoding)
  local data = tokens.encode(parser.parse_all(source), position.new(source, encoding or "utf-8"))
  local out, line, char = {}, 0, 0
  for i = 1, #data, 5 do
    if data[i] > 0 then char = 0 end
    line = line + data[i]
    char = char + data[i + 1]
    out[#out + 1] = { line, char, data[i + 2], TYPES[data[i + 3] + 1], data[i + 4] == 1 }
  end
  return out
end

h.describe("lsp positions", function()
  h.it("counts bytes in UTF-8 and code units in UTF-16", function()
    local src = 'let s = "é" + x'
    h.eq(position.new(src, "utf-8"):to_lsp(1, 16), { line = 0, character = 15 })
    h.eq(position.new(src, "utf-16"):to_lsp(1, 16), { line = 0, character = 14 })
  end)
  h.it("counts a character outside the BMP as two UTF-16 units", function()
    local src = 'x\n"\240\159\152\128" y'
    h.eq(position.new(src, "utf-16"):to_lsp(2, 8), { line = 1, character = 5 })
    h.eq(position.new(src, "utf-16"):length(2, 1, 7), 4)
  end)
end)

h.describe("lsp semantic tokens", function()
  h.it("has the legend in the agreed order", function()
    h.eq(TYPES, { "keyword", "string", "number", "comment", "operator", "type",
                  "enumMember", "function", "parameter", "property", "variable" })
    h.eq(tokens.LEGEND.tokenModifiers, { "declaration" })
  end)
  h.it("classifies a function, its parameter and their uses", function()
    h.eq(rows("let f x = x + 1"), {
      { 0, 0, 3, "keyword", false },
      { 0, 4, 1, "function", true },
      { 0, 6, 1, "parameter", true },
      { 0, 8, 1, "operator", false },
      { 0, 10, 1, "variable", false },
      { 0, 12, 1, "operator", false },
      { 0, 14, 1, "number", false },
    })
  end)
  h.it("classifies types and constructors", function()
    local r = rows("type T = | A | B\nlet v = A")
    h.eq(r[2], { 0, 5, 1, "type", true })
    h.eq(r[4], { 0, 11, 1, "enumMember", true })
    h.eq(r[5], { 0, 15, 1, "enumMember", true })
    h.eq(r[7], { 1, 4, 1, "variable", true })
    h.eq(r[9], { 1, 8, 1, "enumMember", false })
  end)
  h.it("classifies record fields and annotations", function()
    local r = rows("let p (n : number) = { x = n }.x")
    local found = {}
    for _, row in ipairs(r) do found[row[2]] = row[4] end
    h.eq(found[11], "type")
    h.eq(found[23], "property")
    h.eq(found[31], "property")
  end)
  h.it("emits comments", function()
    h.eq(rows("-- c\n1")[1], { 0, 0, 4, "comment", false })
  end)
  h.it("splits a string that spans lines", function()
    h.eq(rows('"ab\ncd"'), { { 0, 0, 3, "string", false }, { 1, 0, 3, "string", false } })
  end)
  h.it("leaves the \\r of a CRLF line out of a split string's length", function()
    h.eq(rows('let s = "a\nb\r\nc"')[5], { 1, 0, 1, "string", false })
  end)
  h.it("uses only the lexer's classes inside a statement that failed to parse", function()
    local r = rows("let b = )\nlet ok = 1")
    h.eq(r[2], { 0, 4, 1, "variable", false })
    h.eq(r[5], { 1, 4, 2, "variable", true })
  end)
  h.it("measures in UTF-16 when asked", function()
    local r = rows('let s = "é" + x', "utf-16")
    h.eq(r[4], { 0, 8, 3, "string", false })
    h.eq(r[6], { 0, 14, 1, "variable", false })
  end)
end)
