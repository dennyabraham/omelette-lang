local h = require("spec.support.harness")
local json = require("omelette.json")
local server = require("omelette.lsp.server")

local URI = "file:///t.egg"

-- A server whose outgoing messages are collected, already round-tripped through JSON so
-- tests see what a client would.
local function start(encodings)
  local sent = {}
  local s = server.new(function(m) sent[#sent + 1] = assert(json.decode(json.encode(m))) end)
  local caps = encodings and { general = { positionEncodings = json.array(encodings) } } or {}
  s:handle({ jsonrpc = "2.0", id = 1, method = "initialize", params = { capabilities = caps } })
  s:handle({ jsonrpc = "2.0", method = "initialized", params = {} })
  return s, sent
end

local function open(s, text)
  s:handle({ jsonrpc = "2.0", method = "textDocument/didOpen",
             params = { textDocument = { uri = URI, languageId = "omelette", version = 1, text = text } } })
end

-- Runs fn while the checker fails, as it does on input the compiler cannot handle.
local typecheck = require("omelette.typecheck")
local function while_check_fails(fn)
  local check = typecheck.check
  typecheck.check = function() error("stack overflow") end
  local ok, err = pcall(fn)
  typecheck.check = check
  assert(ok, err)
end

local function last(sent, method)
  for i = #sent, 1, -1 do if sent[i].method == method then return sent[i] end end
end

local function raw_last(s, method, text)
  -- the exact JSON a client receives for the last message of a method
  local out
  local srv = server.new(function(m) if m.method == method then out = json.encode(m) end end)
  srv:handle({ jsonrpc = "2.0", id = 1, method = "initialize", params = { capabilities = {} } })
  srv:handle({ jsonrpc = "2.0", method = "textDocument/didOpen",
               params = { textDocument = { uri = URI, version = 1, text = text } } })
  return out
end

h.describe("lsp server", function()
  h.it("chooses utf-8 when offered, else utf-16", function()
    local _, sent = start({ "utf-16", "utf-8" })
    local caps = sent[1].result.capabilities
    h.eq(caps.positionEncoding, "utf-8")
    h.eq(caps.textDocumentSync, { openClose = true, change = 1 })
    h.eq(caps.semanticTokensProvider.full, true)
    h.eq(sent[1].result.serverInfo.name, "omelette")
    local _, sent2 = start()
    h.eq(sent2[1].result.capabilities.positionEncoding, "utf-16")
  end)
  h.it("publishes a diagnostic with its range on open", function()
    local s, sent = start({ "utf-8" })
    open(s, "let b = )")
    local p = last(sent, "textDocument/publishDiagnostics").params
    h.eq(p.uri, URI)
    h.eq(#p.diagnostics, 1)
    local d = p.diagnostics[1]
    h.eq(d.range, { start = { line = 0, character = 8 }, ["end"] = { line = 0, character = 9 } })
    h.eq(d.severity, 1)
    h.eq(d.source, "omelette")
  end)
  h.it("gives a stray emoji one diagnostic two UTF-16 units wide", function()
    local s, sent = start()
    open(s, "let x = 1 \240\159\152\128 + 1")
    local d = last(sent, "textDocument/publishDiagnostics").params.diagnostics
    h.eq(#d, 1)
    h.eq(d[1].range, { start = { line = 0, character = 10 }, ["end"] = { line = 0, character = 12 } })
  end)
  h.it("clears diagnostics when a change fixes the file", function()
    local s, sent = start({ "utf-8" })
    open(s, "let b = )")
    s:handle({ jsonrpc = "2.0", method = "textDocument/didChange",
               params = { textDocument = { uri = URI, version = 2 },
                          contentChanges = { { text = "let b = 1" } } } })
    h.eq(#last(sent, "textDocument/publishDiagnostics").params.diagnostics, 0)
  end)
  h.it("encodes empty diagnostics as an array", function()
    h.truthy(raw_last(nil, "textDocument/publishDiagnostics", ""):find('"diagnostics":%[%]'))
    h.truthy(raw_last(nil, "textDocument/publishDiagnostics", "-- only a comment\n"):find('"diagnostics":%[%]'))
  end)
  h.it("returns semantic tokens for an open document", function()
    local s, sent = start({ "utf-8" })
    open(s, "let f x = x")
    s:handle({ jsonrpc = "2.0", id = 2, method = "textDocument/semanticTokens/full",
               params = { textDocument = { uri = URI } } })
    local data = sent[#sent].result.data
    h.eq({ data[1], data[2], data[3], data[4] }, { 0, 0, 3, 0 })
  end)
  h.it("returns empty semantic tokens for an unknown document", function()
    local out
    local s = server.new(function(m) out = json.encode(m) end)
    s:handle({ jsonrpc = "2.0", id = 1, method = "initialize", params = { capabilities = {} } })
    s:handle({ jsonrpc = "2.0", id = 2, method = "textDocument/semanticTokens/full",
               params = { textDocument = { uri = "file:///none.egg" } } })
    h.truthy(out:find('"data":%[%]'))
  end)
  h.it("survives a file it cannot check", function()
    local s, sent = start({ "utf-8" })
    while_check_fails(function() open(s, "let a = 1") end)
    local d = last(sent, "textDocument/publishDiagnostics").params.diagnostics
    h.eq(#d, 1)
    h.truthy(d[1].message:find("^omelette could not check this file: "))
    h.truthy(last(sent, "window/logMessage"))
    s:handle({ jsonrpc = "2.0", id = 3, method = "textDocument/semanticTokens/full",
               params = { textDocument = { uri = URI } } })
    h.eq(sent[#sent].id, 3)
    h.eq(type(sent[#sent].result.data), "table")
  end)
  h.it("answers an unknown request with method not found", function()
    local s, sent = start()
    s:handle({ jsonrpc = "2.0", id = 9, method = "textDocument/frobnicate", params = {} })
    h.eq(sent[#sent].error.code, -32601)
    local n = #sent
    s:handle({ jsonrpc = "2.0", method = "$/unknownNotification", params = {} })
    h.eq(#sent, n)
  end)
  h.it("answers a message that is not an object with invalid request", function()
    local s, sent = start()
    for _, m in ipairs({ 5, "x", json.null }) do
      local n = #sent
      h.eq(s:handle(m), nil)
      h.eq(#sent, n + 1)
      h.eq(sent[#sent].error.code, -32600)
      h.eq(sent[#sent].id, json.null)
    end
  end)
  h.it("refuses requests after shutdown", function()
    local s, sent = start()
    open(s, "let x = 1")
    s:handle({ jsonrpc = "2.0", id = 5, method = "shutdown" })
    s:handle({ jsonrpc = "2.0", id = 6, method = "textDocument/semanticTokens/full",
               params = { textDocument = { uri = URI } } })
    h.eq(sent[#sent].id, 6)
    h.eq(sent[#sent].error.code, -32600)
  end)
  h.it("answers a frame that is not JSON with a parse error", function()
    local function frame(body) return "Content-Length: " .. #body .. "\r\n\r\n" .. body end
    local input = frame("{bad") .. frame('{"jsonrpc":"2.0","method":"exit"}')
    local pos, written = 1, {}
    local reader = {
      read = function(_, what)
        if what == "*l" then
          local e = input:find("\n", pos, true)
          if not e then return nil end
          local l = input:sub(pos, e - 1); pos = e + 1; return l
        end
        local s = input:sub(pos, pos + what - 1); pos = pos + what; return s
      end,
    }
    local writer = { write = function(_, ...) for _, p in ipairs({ ... }) do written[#written + 1] = p end end,
                     flush = function() end }
    h.eq(server.run(reader, writer), 1)
    local out = table.concat(written)
    h.truthy(out:find('"code":%-32700'))
    h.truthy(out:find('"id":null'))
  end)
  local FIXTURE = "let n : number = 1\nlet f x = x + n\ntype T = | A | B\nlet v = A"
  local function ask(s, sent, method, line, character)
    s:handle({ jsonrpc = "2.0", id = 40, method = method,
               params = { textDocument = { uri = URI }, position = { line = line, character = character } } })
    h.eq(sent[#sent].id, 40)
    return sent[#sent].result
  end
  local function hover_text(s, sent, line, character)
    return ask(s, sent, "textDocument/hover", line, character).contents.value
  end
  h.it("offers hover and definition", function()
    local _, sent = start()
    h.eq(sent[1].result.capabilities.hoverProvider, true)
    h.eq(sent[1].result.capabilities.definitionProvider, true)
  end)
  h.it("hovers a typed name", function()
    local s, sent = start({ "utf-8" })
    open(s, FIXTURE)
    h.truthy(hover_text(s, sent, 1, 14):find("n : number", 1, true))
  end)
  h.it("hovers a name inside a branch checked against a declared type", function()
    local s, sent = start({ "utf-8" })
    open(s, "let n : number = 1\nlet f (c: boolean): number = if c then n else 0")
    h.truthy(hover_text(s, sent, 1, 39):find("n : number", 1, true))
  end)
  h.it("hovers a name inside a match arm checked against a declared type", function()
    local s, sent = start({ "utf-8" })
    open(s, "let n : number = 1\nlet m (v: number): number = match v with | 1 -> n | _ -> 0")
    h.truthy(hover_text(s, sent, 1, 48):find("n : number", 1, true))
  end)
  h.it("hovers a let of type any with its declaration line", function()
    local s, sent = start({ "utf-8" })
    open(s, "let w = print(1)\nlet z = w")
    h.truthy(hover_text(s, sent, 1, 8):find("let w = print(1)", 1, true))
  end)
  h.it("hovers an unannotated parameter or pattern variable as any", function()
    local s, sent = start({ "utf-8" })
    open(s, FIXTURE .. "\nlet m p = match p with | { q } -> q")
    h.truthy(hover_text(s, sent, 1, 10):find("x : any", 1, true))
    h.truthy(hover_text(s, sent, 4, 34):find("q : any", 1, true))
  end)
  h.it("cuts long hover text short", function()
    local s, sent = start({ "utf-8" })
    local variants = {}
    for i = 1, 40 do variants[i] = "  | V" .. i end
    open(s, "type Big =\n" .. table.concat(variants, "\n") .. "\nlet b = V1\n"
      .. "let long = print(" .. string.rep("1 + ", 100) .. "1)\nlet c = long")
    local t = hover_text(s, sent, 41, 8)
    h.truthy(t:find("type Big =", 1, true))
    h.truthy(not t:find("V40", 1, true))
    h.truthy(t:find("…", 1, true))
    local l = hover_text(s, sent, 43, 8)
    h.truthy(l:find("let long = print(1 + ", 1, true))
    for line in l:gmatch("[^\n]+") do h.truthy(#line <= 130) end
  end)
  h.it("hovers a constructor with its type declaration", function()
    local s, sent = start({ "utf-8" })
    open(s, FIXTURE)
    local r = ask(s, sent, "textDocument/hover", 3, 8)
    h.eq(r.contents.kind, "markdown")
    h.truthy(r.contents.value:find("type T = | A | B", 1, true))
  end)
  h.it("jumps to a definition", function()
    local s, sent = start({ "utf-8" })
    open(s, FIXTURE)
    local r = ask(s, sent, "textDocument/definition", 1, 14)
    h.eq(r.uri, URI)
    h.eq(r.range, { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 5 } })
  end)
  h.it("gives null on no name", function()
    local s, sent = start({ "utf-8" })
    open(s, FIXTURE)
    for _, p in ipairs({ { 0, 15 }, { 0, 200 }, { 50, 0 } }) do
      h.eq(ask(s, sent, "textDocument/hover", p[1], p[2]), json.null)
      h.eq(ask(s, sent, "textDocument/definition", p[1], p[2]), json.null)
    end
  end)
  h.it("gives null for a name from a failed statement", function()
    local s, sent = start({ "utf-8" })
    open(s, "let b = )\nlet c = b")
    h.eq(ask(s, sent, "textDocument/hover", 1, 8), json.null)
  end)
  h.it("gives null for a file it could not check", function()
    local s, sent = start({ "utf-8" })
    while_check_fails(function() open(s, "let a = 1") end)
    h.eq(ask(s, sent, "textDocument/hover", 0, 0), json.null)
    h.eq(ask(s, sent, "textDocument/definition", 0, 0), json.null)
  end)
  h.it("hovers under UTF-16", function()
    local s, sent = start()
    open(s, 'let s x = "\195\169" .. x')
    h.eq(ask(s, sent, "textDocument/hover", 0, 17).range.start, { line = 0, character = 17 })
  end)
  local function symbols(s, sent)
    s:handle({ jsonrpc = "2.0", id = 50, method = "textDocument/documentSymbol",
               params = { textDocument = { uri = URI } } })
    h.eq(sent[#sent].id, 50)
    return sent[#sent].result
  end
  h.it("lists the file's symbols", function()
    local s, sent = start({ "utf-8" })
    h.eq(sent[1].result.capabilities.documentSymbolProvider, true)
    open(s, "let f x = x\nlet v = 1\nlet (a, b) = (1, 2)\ntype S = | P | Q")
    local r = symbols(s, sent)
    local got = {}
    for i, sym in ipairs(r) do got[i] = { sym.name, sym.kind } end
    h.eq(got, { { "f", 12 }, { "v", 13 }, { "a", 13 }, { "b", 13 }, { "S", 10 } })
    h.eq(r[1].selectionRange, { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 5 } })
    h.eq(r[1].range["end"], { line = 0, character = 11 })
    h.eq(r[3].selectionRange.start, { line = 2, character = 5 })
    local kids = {}
    for i, c in ipairs(r[5].children) do kids[i] = { c.name, c.kind } end
    h.eq(kids, { { "P", 22 }, { "Q", 22 } })
  end)
  h.it("gives a constructor's symbol a range over its fields", function()
    local s, sent = start({ "utf-8" })
    open(s, "type S = | P { a, b } | Q(x, y)")
    local kids = symbols(s, sent)[1].children
    h.eq(kids[1].range, { start = { line = 0, character = 11 }, ["end"] = { line = 0, character = 21 } })
    h.eq(kids[1].selectionRange, { start = { line = 0, character = 11 }, ["end"] = { line = 0, character = 12 } })
    h.eq(kids[2].range, { start = { line = 0, character = 24 }, ["end"] = { line = 0, character = 31 } })
  end)
  h.it("gives no symbols for a file it could not check", function()
    local out
    local srv = server.new(function(m) if m.id == 50 then out = json.encode(m) end end)
    srv:handle({ jsonrpc = "2.0", id = 1, method = "initialize", params = { capabilities = {} } })
    while_check_fails(function()
      srv:handle({ jsonrpc = "2.0", method = "textDocument/didOpen",
                   params = { textDocument = { uri = URI, version = 1, text = "let a = 1" } } })
    end)
    srv:handle({ jsonrpc = "2.0", id = 50, method = "textDocument/documentSymbol",
                 params = { textDocument = { uri = URI } } })
    h.truthy(out:find('"result":%[%]'))
  end)
  h.it("exits 0 after shutdown and 1 without it", function()
    local s, sent = start()
    s:handle({ jsonrpc = "2.0", id = 5, method = "shutdown" })
    h.eq(sent[#sent].id, 5)
    h.eq(s:handle({ jsonrpc = "2.0", method = "exit" }), 0)
    local s2 = start()
    h.eq(s2:handle({ jsonrpc = "2.0", method = "exit" }), 1)
  end)
end)
