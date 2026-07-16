local errors = require("omelette.errors")
local M = {}

local KEYWORDS = {
  ["let"]=true, ["pub"]=true, ["fn"]=true, ["if"]=true, ["then"]=true,
  ["else"]=true, ["match"]=true, ["with"]=true, ["true"]=true,
  ["false"]=true, ["nil"]=true, ["and"]=true, ["or"]=true, ["not"]=true,
  ["lua"]=true, ["to"]=true,
}

-- longest first so greedy matching works
local MULTI_OPS = { "|>", "->", "..", "==", "~=", "<=", ">=", "<-", "=>" }
local SINGLE_OPS = { ["+"]=true,["-"]=true,["*"]=true,["/"]=true,["%"]=true,
  ["<"]=true,[">"]=true,["="]=true,["#"]=true }
local PUNCT = { ["("]=true,[")"]=true,["{"]=true,["}"]=true,["["]=true,
  ["]"]=true,[","]=true,["."]=true,["|"]=true }

local ESCAPES = { n="\n", t="\t", r="\r", ['"']='"', ["\\"]="\\" }

function M.tokenize(source)
  local toks, i, line, col = {}, 1, 1, 1
  local n = #source
  local function peek(o) return source:sub(i + (o or 0), i + (o or 0)) end
  local function advance()
    local c = source:sub(i, i)
    if c == "\n" then line = line + 1; col = 1 else col = col + 1 end
    i = i + 1
    return c
  end

  while i <= n do
    local c = peek()
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      advance()
    elseif c == "-" and peek(1) == "-" then
      while i <= n and peek() ~= "\n" do advance() end
    elseif c == '"' then
      local startcol = col
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
      if peek() ~= '"' then
        return nil, errors.new("unterminated string", line, startcol, source)
      end
      advance()
      toks[#toks + 1] = { type = "string", value = table.concat(buf), line = line, col = startcol }
    elseif c:match("%d") then
      local startcol = col
      local buf = {}
      while i <= n and peek():match("[%d%.]") do buf[#buf + 1] = advance() end
      toks[#toks + 1] = { type = "number", value = tonumber(table.concat(buf)), line = line, col = startcol }
    elseif c:match("[%a_]") then
      local startcol = col
      local buf = {}
      while i <= n and peek():match("[%w_]") do buf[#buf + 1] = advance() end
      local word = table.concat(buf)
      if word == "_" then
        toks[#toks + 1] = { type = "punct", value = "_", line = line, col = startcol }
      elseif KEYWORDS[word] then
        toks[#toks + 1] = { type = "keyword", value = word, line = line, col = startcol }
      else
        toks[#toks + 1] = { type = "ident", value = word, line = line, col = startcol }
      end
    else
      local startcol = col
      local two = source:sub(i, i + 1)
      local matched
      for _, op in ipairs(MULTI_OPS) do if two == op then matched = op break end end
      if matched then
        advance(); advance()
        toks[#toks + 1] = { type = "op", value = matched, line = line, col = startcol }
      elseif SINGLE_OPS[c] then
        advance()
        toks[#toks + 1] = { type = "op", value = c, line = line, col = startcol }
      elseif PUNCT[c] then
        advance()
        toks[#toks + 1] = { type = "punct", value = c, line = line, col = startcol }
      else
        return nil, errors.new("unexpected character '" .. c .. "'", line, col, source)
      end
    end
  end

  toks[#toks + 1] = { type = "eof", value = "<eof>", line = line, col = col }
  return toks, nil
end

return M
