-- The language server: diagnostics and semantic tokens for open .egg documents.
-- Messages are handled one at a time; analysis runs on every open and change.
local json = require("omelette.json")
local rpc = require("omelette.lsp.rpc")
local position = require("omelette.lsp.position")
local tokens = require("omelette.lsp.tokens")
local names = require("omelette.lsp.names")
local lexer = require("omelette.lexer")
local parser = require("omelette.parser")
local typecheck = require("omelette.typecheck")
local format_type = typecheck.format_type

local M = {}
local Server = {}
Server.__index = Server

function M.new(send)
  return setmetatable({ send = send, docs = {}, encoding = "utf-16", shut_down = false }, Server)
end

function Server:log(message)
  self.send({ jsonrpc = "2.0", method = "window/logMessage",
              params = { type = 1, message = message } })
end

-- Parses and checks a document. Analysis can fail on input the compiler cannot handle
-- (very deep nesting overflows the stack); the document then gets one diagnostic and
-- lexer-only tokens.
local function analyse(text)
  local ok, result = pcall(function()
    local parsed = parser.parse_all(text)
    local diags = {}
    for _, d in ipairs(parsed.diagnostics) do diags[#diags + 1] = d end
    local tdiags, binding_of = typecheck.check(parsed.program)
    for _, d in ipairs(tdiags) do diags[#diags + 1] = d end
    return { parsed = parsed, diags = diags, index = names.index(binding_of) }
  end)
  if ok then return result end
  local lexed = lexer.tokenize(text, { recover = true })
  return {
    parsed = { program = { kind = "program", stmts = {} }, tokens = lexed.tokens, comments = lexed.comments },
    diags = { { message = "omelette could not check this file: " .. tostring(result),
                line = 1, col = 1, end_line = 1, end_col = 2 } },
    failure = tostring(result),
  }
end

function Server:update(uri, text)
  local doc = analyse(text)
  doc.pos = position.new(text, self.encoding)
  doc.text = text
  self.docs[uri] = doc
  if doc.failure then self:log("omelette could not check " .. uri .. ": " .. doc.failure) end
  local out = json.array({})
  for _, d in ipairs(doc.diags) do
    out[#out + 1] = {
      range = { start = doc.pos:to_lsp(d.line, d.col),
                ["end"] = doc.pos:to_lsp(d.end_line or d.line, d.end_col or d.col + 1) },
      severity = 1, source = "omelette", message = d.message,
    }
  end
  self.send({ jsonrpc = "2.0", method = "textDocument/publishDiagnostics",
              params = { uri = uri, diagnostics = out } })
end

local REQUESTS = {}
local NOTIFICATIONS = {}

function REQUESTS.initialize(self, params)
  local offered = params and params.capabilities and params.capabilities.general
    and params.capabilities.general.positionEncodings or {}
  for _, e in ipairs(offered) do if e == "utf-8" then self.encoding = "utf-8" end end
  return {
    capabilities = {
      positionEncoding = self.encoding,
      textDocumentSync = { openClose = true, change = 1 },
      semanticTokensProvider = { legend = tokens.LEGEND, full = true },
      hoverProvider = true,
      definitionProvider = true,
    },
    serverInfo = { name = "omelette", version = require("omelette").version },
  }
end

function REQUESTS.shutdown(self)
  self.shut_down = true
  return json.null
end

REQUESTS["textDocument/semanticTokens/full"] = function(self, params)
  local doc = self.docs[params.textDocument.uri]
  if not doc then return { data = json.array({}) } end
  return { data = json.array(tokens.encode(doc.parsed, doc.pos, doc.index)) }
end

-- The name occurrence at a request's position, with its document, or nil.
local function occurrence(self, params)
  local doc = self.docs[params.textDocument.uri]
  if not doc or not doc.index then return nil end
  local line, col = doc.pos:from_lsp(params.position.line, params.position.character)
  local occ = names.at(doc.index, line, col)
  return occ, doc
end

local function lsp_range(pos, line, col, end_line, end_col)
  return { start = pos:to_lsp(line, col), ["end"] = pos:to_lsp(end_line, end_col) }
end

-- Source text from line:col up to end_line:end_col.
local function slice(pos, line, col, end_line, end_col)
  local out = {}
  for l = line, end_line do
    local s = pos.lines[l] or ""
    out[#out + 1] = s:sub(l == line and col or 1, l == end_line and end_col - 1 or #s)
  end
  return table.concat(out, "\n")
end

local function hover_text(doc, decl)
  if decl.kind == "type" or decl.kind == "enumMember" then
    local n = decl.node
    return slice(doc.pos, n.start_line, n.start_col, n.end_line, n.end_col)
  end
  if decl.type.kind ~= "any" then return decl.name .. " : " .. format_type(decl.type) end
  return ((doc.pos.lines[decl.line] or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

REQUESTS["textDocument/hover"] = function(self, params)
  local occ, doc = occurrence(self, params)
  if not occ then return json.null end
  return {
    contents = { kind = "markdown", value = "```omelette\n" .. hover_text(doc, occ.decl) .. "\n```" },
    range = lsp_range(doc.pos, occ.line, occ.col, occ.line, occ.end_col),
  }
end

REQUESTS["textDocument/definition"] = function(self, params)
  local occ, doc = occurrence(self, params)
  if not occ then return json.null end
  local d = occ.decl
  return { uri = params.textDocument.uri, range = lsp_range(doc.pos, d.line, d.col, d.end_line, d.end_col) }
end

NOTIFICATIONS.initialized = function() end

NOTIFICATIONS["textDocument/didOpen"] = function(self, params)
  self:update(params.textDocument.uri, params.textDocument.text)
end

NOTIFICATIONS["textDocument/didChange"] = function(self, params)
  local changes = params.contentChanges
  self:update(params.textDocument.uri, changes[#changes].text)
end

NOTIFICATIONS["textDocument/didClose"] = function(self, params)
  self.docs[params.textDocument.uri] = nil
  self.send({ jsonrpc = "2.0", method = "textDocument/publishDiagnostics",
              params = { uri = params.textDocument.uri, diagnostics = json.array({}) } })
end

-- Returns an exit code for `exit`, otherwise nil.
function Server:handle(msg)
  if type(msg) ~= "table" or msg == json.null then
    self.send({ jsonrpc = "2.0", id = json.null,
                error = { code = -32600, message = "a message must be a JSON object" } })
    return nil
  end
  if msg.method == "exit" then return self.shut_down and 0 or 1 end
  local is_request = msg.id ~= nil and msg.method ~= nil
  if is_request and self.shut_down then
    self.send({ jsonrpc = "2.0", id = msg.id,
                error = { code = -32600, message = "the server has shut down" } })
    return nil
  end
  local handler = (is_request and REQUESTS or NOTIFICATIONS)[msg.method]
  if not handler then
    if is_request then
      self.send({ jsonrpc = "2.0", id = msg.id,
                  error = { code = -32601, message = "method not found: " .. tostring(msg.method) } })
    end
    return nil
  end
  local ok, result = pcall(handler, self, msg.params)
  if not ok then
    self:log("error in " .. msg.method .. ": " .. tostring(result))
    if is_request then
      self.send({ jsonrpc = "2.0", id = msg.id, error = { code = -32603, message = tostring(result) } })
    end
  elseif is_request then
    self.send({ jsonrpc = "2.0", id = msg.id, result = result })
  end
  return nil
end

function M.run(input, output)
  local s = M.new(function(m) rpc.write(output, m) end)
  while true do
    local msg, err = rpc.read(input)
    if not msg then
      if err == "eof" then return 1 end
      s:log(err)
      s.send({ jsonrpc = "2.0", id = json.null, error = { code = -32700, message = err } })
    else
      local code = s:handle(msg)
      if code then return code end
    end
  end
end

return M
