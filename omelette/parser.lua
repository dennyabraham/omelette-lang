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
  self.err = errors.new(msg, t.line, t.col, self.source, t.end_line, t.end_col)
  error("__parse__")  -- internal unwind, caught at top
end
-- Sets node's source range: from `from` (a token, or a node whose range starts the
-- new one) to the end of the last consumed token.
function Parser:finish(node, from)
  local last = self.toks[self.pos - 1] or from
  node.start_line = from.start_line or from.line
  node.start_col = from.start_col or from.col
  node.end_line, node.end_col = last.end_line, last.end_col
  return node
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
    left = self:finish({ kind = "pipe", lhs = left, rhs = right, line = t.line, col = t.col }, left)
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
    left = self:finish({ kind = "binop", op = op, lhs = left, rhs = right, line = t.line, col = t.col }, left)
  end
  return left
end

function Parser:parse_unary()
  local t = self:peek()
  if self:at("op", "-") or self:at("op", "#") or self:at("keyword", "not") then
    self:next()
    local operand = self:parse_unary()
    return self:finish({ kind = "unop", op = t.value, operand = operand, line = t.line, col = t.col }, t)
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
      node = self:finish({ kind = "field", obj = node, name = name.value, line = t.line, col = t.col }, node)
    elseif self:at("punct", "(") then
      local t = self:next()
      local args = {}
      if not self:at("punct", ")") then
        repeat
          if self:at("punct", "_") then
            local ht = self:next()
            args[#args + 1] = self:finish({ kind = "hole", line = ht.line, col = ht.col }, ht)
          else
            args[#args + 1] = self:parse_expr_or_form()
          end
        until not self:accept_comma()
      end
      self:expect("punct", ")")
      node = self:finish({ kind = "call", fn = node, args = args, line = t.line, col = t.col }, node)
    elseif self:at("punct", "[") then
      local t = self:next()
      local key = self:parse_expr()
      self:expect("punct", "]")
      node = self:finish({ kind = "index", obj = node, key = key, line = t.line, col = t.col }, node)
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

-- parse a comprehension qualifier list (shared by list and dict comprehensions):
-- single generator `x <- src`, kv generator `k, v <- src`, or guard `<expr>`.
-- Requires at least one generator.
function Parser:parse_qualifiers()
  local quals, has_gen = {}, false
  repeat
    local cur, nxt = self:peek(), self:peek2()
    local t3, t4 = self.toks[self.pos + 2], self.toks[self.pos + 3]
    if cur.type == "ident" and nxt and nxt.type == "op" and nxt.value == "<-" then
      local name = self:next().value
      self:expect("op", "<-")
      local source = self:parse_expr()
      quals[#quals + 1] = self:finish({ kind = "generator", name = name, value_name = nil, source = source }, cur)
      has_gen = true
    elseif cur.type == "ident" and nxt and nxt.type == "punct" and nxt.value == ","
        and t3 and t3.type == "ident" and t4 and t4.type == "op" and t4.value == "<-" then
      local name = self:next().value
      self:expect("punct", ",")
      local value_name = self:expect("ident").value
      self:expect("op", "<-")
      local source = self:parse_expr()
      quals[#quals + 1] = self:finish({ kind = "generator", name = name, value_name = value_name, source = source }, cur)
      has_gen = true
    else
      local cond = self:parse_expr()
      quals[#quals + 1] = self:finish({ kind = "guard", cond = cond }, cur)
    end
  until not self:accept_comma()
  if not has_gen then self:fail("comprehension needs at least one generator (name <- source)") end
  return quals
end

function Parser:parse_primary()
  local t = self:peek()
  if t.type == "number" then self:next(); return self:finish({ kind = "number", value = t.value, line = t.line, col = t.col }, t) end
  if t.type == "string" then self:next(); return self:finish({ kind = "string", value = t.value, line = t.line, col = t.col }, t) end
  if self:at("keyword", "true") then self:next(); return self:finish({ kind = "bool", value = true, line = t.line, col = t.col }, t) end
  if self:at("keyword", "false") then self:next(); return self:finish({ kind = "bool", value = false, line = t.line, col = t.col }, t) end
  if self:at("keyword", "nil") then self:next(); return self:finish({ kind = "nil", line = t.line, col = t.col }, t) end
  if self:at("keyword", "lua") then
    self:next()
    local s = self:expect("string")
    return self:finish({ kind = "lua_raw", code = s.value, line = t.line, col = t.col }, t)
  end
  if t.type == "ident" then
    self:next()
    if t.value:sub(1, 1):match("%u") then
      -- uppercase ident = constructor
      if self:at("punct", "(") then
        self:next()
        local args = {}
        if not self:at("punct", ")") then
          repeat args[#args + 1] = self:parse_expr() until not self:accept_comma()
        end
        self:expect("punct", ")")
        return self:finish({ kind = "construct", tag = t.value, positional = true, args = args, line = t.line, col = t.col }, t)
      end
      local fields = {}
      if self:at("punct", "{") then
        self:next()
        if not self:at("punct", "}") then
          repeat
            local key = self:expect("ident").value
            self:expect("op", "=")
            local value = self:parse_expr()
            fields[#fields + 1] = { key = key, value = value }
          until not self:accept_comma()
        end
        self:expect("punct", "}")
      end
      return self:finish({ kind = "construct", tag = t.value, fields = fields, line = t.line, col = t.col }, t)
    end
    return self:finish({ kind = "ident", name = t.value, line = t.line, col = t.col }, t)
  end
  if self:at("punct", "(") then
    self:next()
    -- parse_expr_or_form so a parenthesized form (match/if/fn) is usable as a primary.
    local first = self:parse_expr_or_form()
    if self:at("punct", ",") then
      -- tuple: fixed-arity array sugar `(e1, e2, …)`
      local items = { first }
      while self:accept_comma() do
        items[#items + 1] = self:parse_expr()
      end
      self:expect("punct", ")")
      return self:finish({ kind = "array", items = items, line = t.line, col = t.col }, t)
    end
    self:expect("punct", ")")
    -- a parenthesized expression's range includes its parentheses
    return self:finish(first, t)
  end
  if self:at("punct", "[") then
    self:next()
    if self:at("punct", "]") then
      self:next()
      return self:finish({ kind = "array", items = {}, line = t.line, col = t.col }, t)
    end
    local first = self:parse_expr()
    if self:at("keyword", "to") then
      self:next()
      local to_expr = self:parse_expr()
      self:expect("punct", "]")
      return self:finish({ kind = "range", from = first, to = to_expr, line = t.line, col = t.col }, t)
    end
    if self:at("punct", "|") then
      self:next()
      local quals = self:parse_qualifiers()
      self:expect("punct", "]")
      return self:finish({ kind = "comprehension", yield = first, quals = quals, line = t.line, col = t.col }, t)
    end
    local items = { first }
    while self:accept_comma() do
      items[#items + 1] = self:parse_expr()
    end
    self:expect("punct", "]")
    return self:finish({ kind = "array", items = items, line = t.line, col = t.col }, t)
  end
  if self:at("punct", "{") then
    self:next()
    if self:at("punct", "}") then
      self:next()
      return self:finish({ kind = "table", fields = {}, line = t.line, col = t.col }, t)
    end
    -- record literal: `ident = …`; anything else is a dict comprehension
    if self:at("ident") and self:peek2() and self:peek2().type == "op" and self:peek2().value == "=" then
      local fields = {}
      repeat
        local key = self:expect("ident")
        self:expect("op", "=")
        local value = self:parse_expr()
        fields[#fields + 1] = { key = key.value, value = value }
      until not self:accept_comma()
      self:expect("punct", "}")
      return self:finish({ kind = "table", fields = fields, line = t.line, col = t.col }, t)
    end
    -- functional record update `expr with f = v, …`, or dict comprehension `key => value | quals`
    local head = self:parse_expr()
    if self:at("keyword", "with") then
      self:next()  -- consume `with`
      local fields = {}
      repeat
        local key = self:expect("ident").value
        self:expect("op", "=")
        local value = self:parse_expr()
        fields[#fields + 1] = { key = key, value = value }
      until not self:accept_comma()
      self:expect("punct", "}")
      return self:finish({ kind = "record_update", base = head, fields = fields, line = t.line, col = t.col }, t)
    end
    self:expect("op", "=>")
    local value = self:parse_expr()
    self:expect("punct", "|")
    local quals = self:parse_qualifiers()
    self:expect("punct", "}")
    return self:finish({ kind = "dict_comprehension", key = head, value = value, quals = quals, line = t.line, col = t.col }, t)
  end
  self:fail("unexpected token '" .. tostring(t.value) .. "'")
end

local SYNC = { ["let"] = true, ["pub"] = true, ["type"] = true }

-- With self.recover, a failed top-level statement is recorded in self.diags and
-- parsing resumes at the next column-1 let/pub/type after the statement's first token.
-- It resumes from the start, not from the error, because a block is a run of lets:
-- `let x =` with no value reads the top-level lets that follow as its body.
function Parser:parse_program()
  local stmts = {}
  while not self:at("eof") do
    if self.recover then
      local start = self.pos
      local ok, result = pcall(self.parse_statement, self)
      if ok then
        stmts[#stmts + 1] = result
      elseif self.err then
        local failed_at = self.pos
        self.pos = start + 1
        while not self:at("eof") do
          local t = self:peek()
          if t.type == "keyword" and SYNC[t.value] and t.col == 1 then break end
          self.pos = self.pos + 1
        end
        -- An error past the next top-level statement is not where the user's mistake
        -- is: report it on the last token of the unfinished statement. The statements
        -- after it are parsed again and report their own errors.
        if failed_at >= self.pos and not self:at("eof") then
          local last = self.toks[self.pos - 1]
          self.err = errors.new("unfinished statement: line " .. self:peek().line
            .. " starts the next top-level statement", last.line, last.col, self.source,
            last.end_line, last.end_col)
        end
        self.diags[#self.diags + 1] = self.err
        self.err = nil
      else
        error(result, 0)
      end
    else
      stmts[#stmts + 1] = self:parse_statement()
    end
  end
  local program = { kind = "program", stmts = stmts, line = 1, col = 1,
                    start_line = 1, start_col = 1, end_line = 1, end_col = 1 }
  if #stmts > 0 then
    program.start_line, program.start_col = stmts[1].start_line, stmts[1].start_col
    program.end_line, program.end_col = stmts[#stmts].end_line, stmts[#stmts].end_col
  end
  return program
end

function Parser:parse_statement()
  if self:at("keyword", "type") then return self:parse_type_decl() end
  if self:at("keyword", "pub") and self:peek2() and self:peek2().type == "keyword"
      and self:peek2().value == "type" then
    return self:parse_type_decl()
  end
  if self:at("keyword", "pub") or self:at("keyword", "let") then
    return self:parse_let()
  end
  -- a bare top-level expression is allowed (e.g. a call for its side effect)
  return self:parse_expr()
end

-- parse a type expression (only in annotation position): a type name
-- (number/string/boolean/any/… as idents, or the nil keyword), or a function
-- type `(T1, T2) -> R`.
function Parser:parse_type()
  local t = self:peek()
  if self:at("punct", "(") then
    self:next()
    local params = {}
    if not self:at("punct", ")") then
      repeat params[#params + 1] = self:parse_type() until not self:accept_comma()
    end
    self:expect("punct", ")")
    self:expect("op", "->")
    local ret = self:parse_type()
    return self:finish({ kind = "fun_type", params = params, ret = ret }, t)
  end
  if self:at("keyword", "nil") then
    self:next()
    return self:finish({ kind = "type_name", name = "nil" }, t)
  end
  local id = self:expect("ident")
  return self:finish({ kind = "type_name", name = id.value }, t)
end

-- a let pattern must always match; literal and constructor patterns are refutable.
function Parser:check_irrefutable(pat)
  local k = pat.kind
  if k == "lit" or k == "ctor_pat" then
    self:fail("a let pattern must always match; use 'match' for constructor/literal patterns")
  elseif k == "record_pat" then
    for _, f in ipairs(pat.fields) do self:check_irrefutable(f.pat) end
  elseif k == "array_pat" then
    for _, e in ipairs(pat.elems) do self:check_irrefutable(e) end
  end
end

function Parser:parse_let()
  local is_pub = false
  local startt = self:peek()
  if self:at("keyword", "pub") then is_pub = true; self:next() end
  self:expect("keyword", "let")
  -- destructuring binding: `let <pattern> = value` (LHS begins with { [ or ( — a plain
  -- value/function binding always begins with an identifier, so this is unambiguous)
  if self:at("punct", "{") or self:at("punct", "[") or self:at("punct", "(") then
    local pattern = self:parse_pattern()
    self:check_irrefutable(pattern)
    self:expect("op", "=")
    local value = self:parse_block_or_expr()
    return self:finish({ kind = "let", pattern = pattern, value = value,
             is_pub = is_pub, line = startt.line, col = startt.col }, startt)
  end
  local name = self:expect("ident").value
  -- params: bare `ident` (untyped -> false) or parenthesized `(ident: type)`
  local params, param_types = nil, nil
  local has_typed_param = false
  while self:at("ident") or self:at("punct", "(") do
    params = params or {}
    param_types = param_types or {}
    if self:at("punct", "(") then
      self:next()
      local pname = self:expect("ident").value
      self:expect("op", ":")
      local ptype = self:parse_type()
      self:expect("punct", ")")
      params[#params + 1] = pname
      param_types[#params] = ptype
      has_typed_param = true
    else
      params[#params + 1] = self:next().value
      param_types[#params] = false
    end
  end
  if not has_typed_param then param_types = nil end
  -- return type (functions) or value-binding type
  local ret_type, value_type = nil, nil
  if self:at("op", ":") then
    self:next()
    local t = self:parse_type()
    if params then ret_type = t else value_type = t end
  end
  self:expect("op", "=")
  local value = self:parse_block_or_expr()
  return self:finish({ kind = "let", name = name, params = params, param_types = param_types,
           ret_type = ret_type, value_type = value_type, value = value,
           is_pub = is_pub, line = startt.line, col = startt.col }, startt)
end

function Parser:parse_type_decl()
  local is_pub = false
  local startt = self:peek()
  if self:at("keyword", "pub") then is_pub = true; self:next() end
  self:expect("keyword", "type")
  local name = self:expect("ident").value
  self:expect("op", "=")
  local variants = {}
  if self:at("punct", "|") then self:next() end  -- optional leading |
  repeat
    local cname = self:expect("ident")
    if not cname.value:sub(1, 1):match("%u") then
      self:fail("constructor names must be capitalized")
    end
    if self:at("punct", "(") then
      self:next()
      local arity = 0
      if not self:at("punct", ")") then
        repeat self:expect("ident"); arity = arity + 1 until not self:accept_comma()
      end
      self:expect("punct", ")")
      variants[#variants + 1] = { name = cname.value, positional = true, arity = arity }
    else
      local vfields = {}
      if self:at("punct", "{") then
        self:next()
        if not self:at("punct", "}") then
          repeat vfields[#vfields + 1] = self:expect("ident").value until not self:accept_comma()
        end
        self:expect("punct", "}")
      end
      variants[#variants + 1] = { name = cname.value, fields = vfields }
    end
  until not (self:at("punct", "|") and self:next())
  return self:finish({ kind = "type_decl", name = name, is_pub = is_pub, variants = variants,
           line = startt.line, col = startt.col }, startt)
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
  return self:finish({ kind = "block", stmts = stmts, result = result,
           line = stmts[1].line, col = stmts[1].col }, stmts[1])
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
  return self:finish({ kind = "lambda", params = params, body = body, line = t.line, col = t.col }, t)
end

function Parser:parse_if()
  local t = self:expect("keyword", "if")
  local cond = self:parse_expr()
  self:expect("keyword", "then")
  local then_branch = self:parse_expr_or_form()
  self:expect("keyword", "else")
  local else_branch = self:parse_expr_or_form()
  return self:finish({ kind = "if", cond = cond, then_branch = then_branch,
           else_branch = else_branch, line = t.line, col = t.col }, t)
end

function Parser:parse_pattern()
  local t = self:peek()
  if self:at("punct", "_") then self:next(); return self:finish({ kind = "wildcard" }, t) end
  -- negative number literal: `-` directly followed by a number token → negated numeric lit.
  -- (Only a numeric follower triggers this; `-x` stays an error, unchanged.)
  if self:at("op", "-") and self:peek2() and self:peek2().type == "number" then
    self:next()                 -- consume '-'
    local num = self:next()     -- the number token (num.value is a Lua number)
    return self:finish({ kind = "lit", value = -num.value, lit_kind = "number" }, t)
  end
  if self:at("punct", "[") then
    self:next()
    local elems = {}
    if not self:at("punct", "]") then
      repeat elems[#elems + 1] = self:parse_pattern() until not self:accept_comma()
    end
    self:expect("punct", "]")
    return self:finish({ kind = "array_pat", elems = elems }, t)
  end
  if self:at("punct", "(") then
    self:next()
    local elems = {}
    repeat elems[#elems + 1] = self:parse_pattern() until not self:accept_comma()
    self:expect("punct", ")")
    return self:finish({ kind = "array_pat", elems = elems }, t)
  end
  if self:at("punct", "{") then
    self:next()
    local fields = {}
    if not self:at("punct", "}") then
      repeat
        local keytok = self:expect("ident")
        local key = keytok.value
        local pat
        if self:at("op", ":") then self:next(); pat = self:parse_pattern()
        else pat = self:finish({ kind = "var", name = key }, keytok) end
        fields[#fields + 1] = { key = key, pat = pat }
      until not self:accept_comma()
    end
    self:expect("punct", "}")
    return self:finish({ kind = "record_pat", fields = fields }, t)
  end
  if self:at("number") or self:at("string") or self:at("keyword", "true")
      or self:at("keyword", "false") or self:at("keyword", "nil") then
    local lit = self:parse_primary()
    return self:finish({ kind = "lit", value = lit.value, lit_kind = lit.kind }, t)
  end
  local id = self:expect("ident")
  if id.value:sub(1, 1):match("%u") then
    -- uppercase = constructor pattern
    if self:at("punct", "(") then
      self:next()
      local args = {}
      if not self:at("punct", ")") then
        repeat args[#args + 1] = self:parse_pattern() until not self:accept_comma()
      end
      self:expect("punct", ")")
      return self:finish({ kind = "ctor_pat", tag = id.value, positional = true, args = args }, t)
    end
    local fields = {}
    if self:at("punct", "{") then
      self:next()
      if not self:at("punct", "}") then
        repeat
          local keytok = self:expect("ident")
          local key = keytok.value
          local p
          if self:at("op", ":") then self:next(); p = self:parse_pattern()
          else p = self:finish({ kind = "var", name = key }, keytok) end
          fields[#fields + 1] = { key = key, pat = p }
        until not self:accept_comma()
      end
      self:expect("punct", "}")
    end
    return self:finish({ kind = "ctor_pat", tag = id.value, fields = fields }, t)
  end
  return self:finish({ kind = "var", name = id.value }, t)
end

function Parser:parse_match()
  local t = self:expect("keyword", "match")
  local subject = self:parse_expr()
  self:expect("keyword", "with")
  local cases = {}
  while self:at("punct", "|") do
    self:next()
    local pattern = self:parse_pattern()
    local guard = nil
    if self:at("keyword", "when") then self:next(); guard = self:parse_expr() end
    self:expect("op", "->")
    local body = self:parse_expr_or_form()
    cases[#cases + 1] = { pattern = pattern, guard = guard, body = body }
  end
  if #cases == 0 then self:fail("match needs at least one | case") end
  return self:finish({ kind = "match", subject = subject, cases = cases, line = t.line, col = t.col }, t)
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

-- Parses as much of source as it can, for editors: never fails on bad input.
-- Returns { program, tokens, comments, diagnostics }, diagnostics in source order.
function M.parse_all(source)
  local lexed = lexer.tokenize(source, { recover = true })
  local p = new_parser(lexed.tokens, source)
  p.recover, p.diags = true, {}
  local program = p:parse_program()
  local diags = {}
  for i, d in ipairs(lexed.diagnostics) do diags[#diags + 1] = { d = d, i = i } end
  for i, d in ipairs(p.diags) do diags[#diags + 1] = { d = d, i = #lexed.diagnostics + i } end
  table.sort(diags, function(a, b)
    if a.d.line ~= b.d.line then return a.d.line < b.d.line end
    if a.d.col ~= b.d.col then return a.d.col < b.d.col end
    return a.i < b.i
  end)
  for i, e in ipairs(diags) do diags[i] = e.d end
  return { program = program, tokens = lexed.tokens, comments = lexed.comments, diagnostics = diags }
end

M._Parser = Parser  -- exposed so Task 5 can extend it
M._new_parser = new_parser
M._run = run
return M
