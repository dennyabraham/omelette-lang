local lexer = require("omelette.lexer")
local errors = require("omelette.errors")
local M = {}

local BIN_PREC = {
  ["or"] = 1, ["and"] = 2,
  ["=="] = 3, ["~="] = 3, ["<"] = 3, ["<="] = 3, [">"] = 3, [">="] = 3,
  [".."] = 4,
  ["+"] = 5, ["-"] = 5,
  ["*"] = 6, ["/"] = 6, ["%"] = 6,
}

local Parser = {}
Parser.__index = Parser

local function new_parser(toks, source)
  return setmetatable({ toks = toks, pos = 1, source = source, err = nil }, Parser)
end

function Parser:peek() return self.toks[self.pos] end
function Parser:next() local t = self.toks[self.pos]; self.pos = self.pos + 1; return t end
function Parser:at(kind, value)
  local t = self:peek()
  if t.type ~= kind then return false end
  if value ~= nil and t.value ~= value then return false end
  return true
end
function Parser:fail(msg)
  local t = self:peek()
  self.err = errors.new(msg, t.line, t.col, self.source)
  error("__parse__")  -- internal unwind, caught at top
end
function Parser:expect(kind, value)
  if not self:at(kind, value) then
    self:fail("expected " .. (value or kind) .. " but got '" .. tostring(self:peek().value) .. "'")
  end
  return self:next()
end

-- pipe is lowest precedence and left-associative
function Parser:parse_expr() return self:parse_pipe() end

function Parser:parse_pipe()
  local left = self:parse_binop(0)
  while self:at("op", "|>") do
    local t = self:next()
    local right = self:parse_binop(0)
    left = { kind = "pipe", lhs = left, rhs = right, line = t.line, col = t.col }
  end
  return left
end

function Parser:parse_binop(min_prec)
  local left = self:parse_unary()
  while true do
    local t = self:peek()
    local op = (t.type == "op" or t.type == "keyword") and t.value or nil
    local prec = op and BIN_PREC[op]
    if not prec or prec < min_prec then break end
    self:next()
    local right = self:parse_binop(prec + 1)
    left = { kind = "binop", op = op, lhs = left, rhs = right, line = t.line, col = t.col }
  end
  return left
end

function Parser:parse_unary()
  local t = self:peek()
  if self:at("op", "-") or self:at("keyword", "not") then
    self:next()
    local operand = self:parse_unary()
    return { kind = "unop", op = t.value, operand = operand, line = t.line, col = t.col }
  end
  return self:parse_postfix()
end

-- field access and calls bind tightest
function Parser:parse_postfix()
  local node = self:parse_primary()
  while true do
    if self:at("punct", ".") then
      local t = self:next()
      local name = self:expect("ident")
      node = { kind = "field", obj = node, name = name.value, line = t.line, col = t.col }
    elseif self:at("punct", "(") then
      local t = self:next()
      local args = {}
      if not self:at("punct", ")") then
        repeat
          if self:at("punct", "_") then
            local ht = self:next()
            args[#args + 1] = { kind = "hole", line = ht.line, col = ht.col }
          else
            args[#args + 1] = self:parse_expr()
          end
        until not self:accept_comma()
      end
      self:expect("punct", ")")
      node = { kind = "call", fn = node, args = args, line = t.line, col = t.col }
    else
      break
    end
  end
  return node
end

function Parser:accept_comma()
  if self:at("punct", ",") then self:next(); return true end
  return false
end

function Parser:peek2() return self.toks[self.pos + 1] end

function Parser:parse_primary()
  local t = self:peek()
  if t.type == "number" then self:next(); return { kind = "number", value = t.value, line = t.line, col = t.col } end
  if t.type == "string" then self:next(); return { kind = "string", value = t.value, line = t.line, col = t.col } end
  if self:at("keyword", "true") then self:next(); return { kind = "bool", value = true, line = t.line, col = t.col } end
  if self:at("keyword", "false") then self:next(); return { kind = "bool", value = false, line = t.line, col = t.col } end
  if self:at("keyword", "nil") then self:next(); return { kind = "nil", line = t.line, col = t.col } end
  if self:at("keyword", "lua") then
    self:next()
    local s = self:expect("string")
    return { kind = "lua_raw", code = s.value, line = t.line, col = t.col }
  end
  if t.type == "ident" then self:next(); return { kind = "ident", name = t.value, line = t.line, col = t.col } end
  if self:at("punct", "(") then
    self:next()
    local e = self:parse_expr()
    self:expect("punct", ")")
    return e
  end
  if self:at("punct", "[") then
    self:next()
    if self:at("punct", "]") then
      self:next()
      return { kind = "array", items = {}, line = t.line, col = t.col }
    end
    local first = self:parse_expr()
    if self:at("punct", "|") then
      self:next()
      local quals, has_gen = {}, false
      repeat
        local cur, nxt = self:peek(), self:peek2()
        if cur.type == "ident" and nxt and nxt.type == "op" and nxt.value == "<-" then
          local name = self:next().value
          self:expect("op", "<-")
          local source = self:parse_expr()
          quals[#quals + 1] = { kind = "generator", name = name, source = source }
          has_gen = true
        else
          local cond = self:parse_expr()
          quals[#quals + 1] = { kind = "guard", cond = cond }
        end
      until not self:accept_comma()
      if not has_gen then self:fail("comprehension needs at least one generator (name <- source)") end
      self:expect("punct", "]")
      return { kind = "comprehension", yield = first, quals = quals, line = t.line, col = t.col }
    end
    local items = { first }
    while self:accept_comma() do
      items[#items + 1] = self:parse_expr()
    end
    self:expect("punct", "]")
    return { kind = "array", items = items, line = t.line, col = t.col }
  end
  if self:at("punct", "{") then
    self:next()
    local fields = {}
    if not self:at("punct", "}") then
      repeat
        local key = self:expect("ident")
        self:expect("op", "=")
        local value = self:parse_expr()
        fields[#fields + 1] = { key = key.value, value = value }
      until not self:accept_comma()
    end
    self:expect("punct", "}")
    return { kind = "table", fields = fields, line = t.line, col = t.col }
  end
  self:fail("unexpected token '" .. tostring(t.value) .. "'")
end

function Parser:parse_program()
  local stmts = {}
  while not self:at("eof") do
    stmts[#stmts + 1] = self:parse_statement()
  end
  return { kind = "program", stmts = stmts, line = 1, col = 1 }
end

function Parser:parse_statement()
  if self:at("keyword", "pub") or self:at("keyword", "let") then
    return self:parse_let()
  end
  -- a bare top-level expression is allowed (e.g. a call for its side effect)
  return self:parse_expr()
end

function Parser:parse_let()
  local is_pub = false
  local startt = self:peek()
  if self:at("keyword", "pub") then is_pub = true; self:next() end
  self:expect("keyword", "let")
  local name = self:expect("ident").value
  local params = nil
  while self:at("ident") do
    params = params or {}
    params[#params + 1] = self:next().value
  end
  self:expect("op", "=")
  local value = self:parse_block_or_expr()
  return { kind = "let", name = name, params = params, value = value,
           is_pub = is_pub, line = startt.line, col = startt.col }
end

function Parser:parse_block_or_expr()
  -- a block is a run of `let` statements terminated by a trailing expression
  if not self:at("keyword", "let") then
    return self:parse_expr_or_form()
  end
  local stmts = {}
  while self:at("keyword", "let") do
    stmts[#stmts + 1] = self:parse_let()
  end
  local result = self:parse_expr_or_form()
  return { kind = "block", stmts = stmts, result = result,
           line = stmts[1].line, col = stmts[1].col }
end

-- expression position that may also begin with fn/if/match keyword forms
function Parser:parse_expr_or_form()
  if self:at("keyword", "fn") then return self:parse_lambda() end
  if self:at("keyword", "if") then return self:parse_if() end
  if self:at("keyword", "match") then return self:parse_match() end
  return self:parse_expr()
end

function Parser:parse_lambda()
  local t = self:expect("keyword", "fn")
  local params = {}
  while self:at("ident") do params[#params + 1] = self:next().value end
  self:expect("op", "->")
  local body = self:parse_expr_or_form()
  return { kind = "lambda", params = params, body = body, line = t.line, col = t.col }
end

function Parser:parse_if()
  local t = self:expect("keyword", "if")
  local cond = self:parse_expr()
  self:expect("keyword", "then")
  local then_branch = self:parse_expr_or_form()
  self:expect("keyword", "else")
  local else_branch = self:parse_expr_or_form()
  return { kind = "if", cond = cond, then_branch = then_branch,
           else_branch = else_branch, line = t.line, col = t.col }
end

function Parser:parse_match()
  local t = self:expect("keyword", "match")
  local subject = self:parse_expr()
  self:expect("keyword", "with")
  local cases = {}
  while self:at("punct", "|") do
    self:next()
    local pattern
    if self:at("punct", "_") then
      self:next(); pattern = { kind = "wildcard" }
    else
      local lit = self:parse_primary()
      pattern = { kind = "lit", value = lit.value, lit_kind = lit.kind }
    end
    self:expect("op", "->")
    local body = self:parse_expr_or_form()
    cases[#cases + 1] = { pattern = pattern, body = body }
  end
  if #cases == 0 then self:fail("match needs at least one | case") end
  return { kind = "match", subject = subject, cases = cases, line = t.line, col = t.col }
end

local function run(parser, fn)
  local ok, result = pcall(fn)
  if not ok then
    if parser.err then return nil, parser.err end
    error(result)  -- a real (non-parse) error: re-raise
  end
  return result, nil
end

function M.parse_expr_string(source)
  local toks, lerr = lexer.tokenize(source)
  if not toks then return nil, lerr end
  local p = new_parser(toks, source)
  return run(p, function()
    local e = p:parse_expr_or_form()
    p:expect("eof")
    return e
  end)
end

-- full program parser is completed in Task 5; expose a stub used by tests there
function M.parse(source)
  local toks, lerr = lexer.tokenize(source)
  if not toks then return nil, lerr end
  local p = new_parser(toks, source)
  return run(p, function() return p:parse_program() end)
end

M._Parser = Parser  -- exposed so Task 5 can extend it
M._new_parser = new_parser
M._run = run
return M
