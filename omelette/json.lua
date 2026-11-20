-- JSON for the language server. Lua tables do not say whether they are arrays, so an
-- empty array must be marked with json.array; decoded arrays are marked too.
local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })

local ARRAY = {}
function M.array(t) return setmetatable(t, ARRAY) end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
              ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESC[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local encode

local function encode_table(t, out)
  if getmetatable(t) == ARRAY or t[1] ~= nil then
    out[#out + 1] = "["
    for i = 1, #t do
      if i > 1 then out[#out + 1] = "," end
      encode(t[i], out)
    end
    out[#out + 1] = "]"
  else
    out[#out + 1] = "{"
    local first = true
    for k, v in pairs(t) do
      if not first then out[#out + 1] = "," end
      first = false
      out[#out + 1] = encode_string(tostring(k))
      out[#out + 1] = ":"
      encode(v, out)
    end
    out[#out + 1] = "}"
  end
end

encode = function(v, out)
  local ty = type(v)
  if v == M.null or v == nil then
    out[#out + 1] = "null"
  elseif ty == "boolean" then
    out[#out + 1] = tostring(v)
  elseif ty == "number" then
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      out[#out + 1] = string.format("%d", v)
    else
      out[#out + 1] = string.format("%.17g", v)
    end
  elseif ty == "string" then
    out[#out + 1] = encode_string(v)
  elseif ty == "table" then
    encode_table(v, out)
  else
    error("cannot encode a " .. ty)
  end
end

function M.encode(v)
  local out = {}
  encode(v, out)
  return table.concat(out)
end

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function decoder(text)
  local i = 1
  local function fail(msg) error({ json = msg .. " at byte " .. i }) end
  local function skip() i = text:find("[^ \t\r\n]", i) or (#text + 1) end
  local value

  local function str()
    i = i + 1
    local buf = {}
    while true do
      local c = text:sub(i, i)
      if c == "" then fail("unterminated string") end
      if c == '"' then i = i + 1; break end
      if c == "\\" then
        local e = text:sub(i + 1, i + 1)
        if e == "u" then
          local cp = tonumber(text:sub(i + 2, i + 5), 16)
          if not cp then fail("bad \\u escape") end
          i = i + 6
          if cp >= 0xD800 and cp <= 0xDBFF and text:sub(i, i + 1) == "\\u" then
            local lo = tonumber(text:sub(i + 2, i + 5), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
              i = i + 6
            end
          end
          buf[#buf + 1] = utf8_char(cp)
        else
          local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
                        n = "\n", r = "\r", t = "\t" }
          if not map[e] then fail("bad escape") end
          buf[#buf + 1] = map[e]
          i = i + 2
        end
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    end
    return table.concat(buf)
  end

  value = function()
    skip()
    local c = text:sub(i, i)
    if c == "{" then
      i = i + 1
      local obj = {}
      skip()
      if text:sub(i, i) == "}" then i = i + 1; return obj end
      while true do
        skip()
        if text:sub(i, i) ~= '"' then fail("expected a key") end
        local k = str()
        skip()
        if text:sub(i, i) ~= ":" then fail("expected ':'") end
        i = i + 1
        obj[k] = value()
        skip()
        local d = text:sub(i, i)
        i = i + 1
        if d == "}" then return obj end
        if d ~= "," then fail("expected ',' or '}'") end
      end
    elseif c == "[" then
      i = i + 1
      local arr = M.array({})
      skip()
      if text:sub(i, i) == "]" then i = i + 1; return arr end
      while true do
        arr[#arr + 1] = value()
        skip()
        local d = text:sub(i, i)
        i = i + 1
        if d == "]" then return arr end
        if d ~= "," then fail("expected ',' or ']'") end
      end
    elseif c == '"' then
      return str()
    elseif text:sub(i, i + 3) == "true" then
      i = i + 4; return true
    elseif text:sub(i, i + 4) == "false" then
      i = i + 5; return false
    elseif text:sub(i, i + 3) == "null" then
      i = i + 4; return M.null
    else
      local num = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
      local n = num and tonumber(num)
      if not n then fail("unexpected input") end
      i = i + #num
      return n
    end
  end

  return function()
    local v = value()
    skip()
    if i <= #text then fail("trailing input") end
    return v
  end
end

function M.decode(text)
  local ok, result = pcall(decoder(text))
  if ok then return result end
  if type(result) == "table" and result.json then return nil, result.json end
  return nil, tostring(result)
end

return M
