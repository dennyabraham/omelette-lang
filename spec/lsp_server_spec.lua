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
    open(s, string.rep("(", 200000))
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
  h.it("exits 0 after shutdown and 1 without it", function()
    local s, sent = start()
    s:handle({ jsonrpc = "2.0", id = 5, method = "shutdown" })
    h.eq(sent[#sent].id, 5)
    h.eq(s:handle({ jsonrpc = "2.0", method = "exit" }), 0)
    local s2 = start()
    h.eq(s2:handle({ jsonrpc = "2.0", method = "exit" }), 1)
  end)
end)
