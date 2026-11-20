-- Language server message framing: a header block ending in a blank line, of which
-- only Content-Length matters, followed by that many bytes of JSON.
local json = require("omelette.json")
local M = {}

function M.read(input)
  local length
  while true do
    local line = input:read("*l")
    if line == nil then return nil, "eof" end
    line = line:gsub("\r$", "")
    if line == "" then
      if length then break end
    else
      local n = line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")
      if n then length = tonumber(n) end
    end
  end
  local body = length > 0 and input:read(length) or ""
  if body == nil or #body < length then return nil, "eof" end
  local msg, err = json.decode(body)
  if msg == nil then return nil, "parse error: " .. err end
  return msg, nil
end

function M.write(output, msg)
  local body = json.encode(msg)
  output:write("Content-Length: " .. #body .. "\r\n\r\n", body)
  output:flush()
end

return M
