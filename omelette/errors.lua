local M = {}

local function nth_line(source, n)
  local i, cur = 1, 1
  for line in (source .. "\n"):gmatch("(.-)\n") do
    if cur == n then return line end
    cur = cur + 1
    i = i + 1
  end
  return nil
end

function M.new(message, line, col, source)
  local snippet = source and nth_line(source, line) or nil
  return { message = message, line = line, col = col, snippet = snippet }
end

function M.render(d)
  local out = string.format("error: %s (line %d, col %d)", d.message, d.line, d.col)
  if d.snippet then
    out = out .. "\n  " .. d.snippet .. "\n  " .. string.rep(" ", (d.col or 1) - 1) .. "^"
  end
  return out
end

return M
