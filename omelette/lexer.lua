local errors = require("omelette.errors")
local M = {}

local KEYWORDS = {
  ["let"]=true, ["pub"]=true, ["fn"]=true, ["if"]=true, ["then"]=true,
  ["else"]=true, ["match"]=true, ["with"]=true, ["true"]=true,
  ["false"]=true, ["nil"]=true, ["and"]=true, ["or"]=true, ["not"]=true,
  ["lua"]=true, ["to"]=true, ["when"]=true, ["type"]=true,
}

-- longest first so greedy matching works
local MULTI_OPS = { "|>", "->", "..", "==", "~=", "<=", ">=", "<-", "=>" }
local SINGLE_OPS = { ["+"]=true,["-"]=true,["*"]=true,["/"]=true,["%"]=true,
  ["<"]=true,[">"]=true,["="]=true,["#"]=true,[":"]=true }
local PUNCT = { ["("]=true,[")"]=true,["{"]=true,["}"]=true,["["]=true,
  ["]"]=true,[","]=true,["."]=true,["|"]=true }

local ESCAPES = { n="\n", t="\t", r="\r", ['"']='"', ["\\"]="\\" }

-- The byte length of the UTF-8 character at i, or nil if the bytes there are not one.
local function utf8_length(s, i)
  local b = s:byte(i)
  local len = b < 0x80 and 1 or b >= 0xC2 and b < 0xE0 and 2 or b >= 0xE0 and b < 0xF0 and 3
              or b >= 0xF0 and b < 0xF5 and 4 or nil
  if not len then return nil end
  for k = i + 1, i + len - 1 do
    local cb = s:byte(k)
    if not cb or cb < 0x80 or cb >= 0xC0 then return nil end
  end
  return len
end

-- With opts.recover, an error is recorded and lexing continues, and the result is
-- { tokens, comments, diagnostics }. Without it, the first error is returned.
function M.tokenize(source, opts)
  local recover = opts and opts.recover
  local toks, comments, diags = {}, {}, {}
  local i, line, col = 1, 1, 1
  local n = #source
  local function peek(o) return source:sub(i + (o or 0), i + (o or 0)) end
  local function advance()
    local c = source:sub(i, i)
    if c == "\n" then line = line + 1; col = 1 else col = col + 1 end
    i = i + 1
    return c
  end
  local function push(ty, value, sline, scol)
    toks[#toks + 1] = { type = ty, value = value, line = sline, col = scol,
                        end_line = line, end_col = col }
  end

  while i <= n do
    local c = peek()
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      advance()
    elseif c == "-" and peek(1) == "-" then
      local sline, scol, start = line, col, i
      while i <= n and peek() ~= "\n" do advance() end
      comments[#comments + 1] = { text = source:sub(start, i - 1), line = sline, col = scol,
                                  end_line = line, end_col = col }
    elseif c == '"' then
      local sline, startcol = line, col
      local start = i
      advance()
      local buf = {}
      while i <= n and peek() ~= '"' do
        local ch = advance()
        if ch == "\\" then
          local e = advance()
          buf[#buf + 1] = ESCAPES[e] or e
        else
          buf[#buf + 1] = ch
        end
      end
      if peek() == '"' then
        advance()
        push("string", table.concat(buf), sline, startcol)
      else
        local eol = source:find("\n", start, true) or (n + 1)
        local err = errors.new("unterminated string", sline, startcol, source,
          sline, startcol + (eol - start))
        if not recover then return nil, err end
        diags[#diags + 1] = err
        -- end the string at the end of its first line so the following lines still lex
        local text = source:sub(start + 1, eol - 1)
        i, line, col = start, sline, startcol
        while i < eol do advance() end
        push("string", text, sline, startcol)
      end
    elseif c:match("%d") then
      local startcol = col
      local buf = {}
      while i <= n and peek():match("[%d%.]") do buf[#buf + 1] = advance() end
      push("number", tonumber(table.concat(buf)), line, startcol)
    elseif c:match("[%a_]") then
      local startcol = col
      local buf = {}
      while i <= n and peek():match("[%w_]") do buf[#buf + 1] = advance() end
      local word = table.concat(buf)
      if word == "_" then
        push("punct", "_", line, startcol)
      elseif KEYWORDS[word] then
        push("keyword", word, line, startcol)
      else
        push("ident", word, line, startcol)
      end
    else
      local startcol = col
      local two = source:sub(i, i + 1)
      local matched
      for _, op in ipairs(MULTI_OPS) do if two == op then matched = op break end end
      if matched then
        advance(); advance()
        push("op", matched, line, startcol)
      elseif SINGLE_OPS[c] then
        advance()
        push("op", c, line, startcol)
      elseif PUNCT[c] then
        advance()
        push("punct", c, line, startcol)
      else
        local len = utf8_length(source, i)
        local shown = len and source:sub(i, i + len - 1) or string.format("\\x%02x", c:byte())
        local err = errors.new("unexpected character '" .. shown .. "'", line, col, source, line, col + (len or 1))
        if not recover then return nil, err end
        diags[#diags + 1] = err
        for _ = 1, len or 1 do advance() end
      end
    end
  end

  push("eof", "<eof>", line, col)
  if recover then return { tokens = toks, comments = comments, diagnostics = diags } end
  return toks, nil
end

return M
