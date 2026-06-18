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
    local items = {}
    if not self:at("punct", "]") then
      repeat items[#items + 1] = self:parse_expr() until not self:accept_comma()
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
    local e = p:parse_expr()
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
