-- Converts compiler positions (1-based line, 1-based byte column) to LSP positions
-- (0-based line, 0-based character in the negotiated encoding).
local M = {}
M.__index = M

function M.new(source, encoding)
  local lines = {}
  for line in (source .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  return setmetatable({ lines = lines, utf16 = encoding == "utf-16" }, M)
end

-- UTF-16 code units in bytes [from, to) of a line: one per UTF-8 lead byte, two for a
-- four-byte sequence.
local function units(s, from, to)
  local n = 0
  for i = from, to - 1 do
    local b = s:byte(i)
    if not b then break end
    if b < 0x80 or b >= 0xC0 then n = n + (b >= 0xF0 and 2 or 1) end
  end
  return n
end

function M:to_lsp(line, col)
  local char = col - 1
  if self.utf16 then char = units(self.lines[line] or "", 1, col) end
  return { line = line - 1, character = char }
end

-- The inverse of to_lsp: an LSP position as a 1-based line and byte column. A character
-- past the end of the line gives a column past it.
function M:from_lsp(line, character)
  if not self.utf16 then return line + 1, character + 1 end
  local s = self.lines[line + 1] or ""
  local col, n = 1, 0
  while n < character and col <= #s do
    local b = s:byte(col)
    local len = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
    n = n + (len == 4 and 2 or 1)
    col = col + len
  end
  return line + 1, col + (character - n)
end

function M:length(line, col, end_col)
  if self.utf16 then return units(self.lines[line] or "", col, end_col) end
  return end_col - col
end

-- The column after a line's last character; a CRLF line's \r is not a character.
function M:line_end(line)
  local l = self.lines[line] or ""
  return #l + (l:sub(-1) == "\r" and 0 or 1)
end

return M
