-- Name occurrences: every use and declaration of a name the checker bound, with its byte
-- range on its line, so hover, definition and semantic tokens can look a name up by position.
local M = {}

-- binding_of maps uses (nodes) and declarations (their name tokens) to declarations.
function M.index(binding_of)
  local out = {}
  for key, decl in pairs(binding_of) do
    local line, col = key.start_line or key.line, key.start_col or key.col
    local end_col = key.end_col
    if key.kind == "construct" or key.kind == "ctor_pat" then end_col = col + #key.tag end
    out[#out + 1] = { line = line, col = col, end_col = end_col, decl = decl,
                      is_decl = line == decl.line and col == decl.col }
  end
  table.sort(out, function(a, b) return a.line < b.line or (a.line == b.line and a.col < b.col) end)
  return out
end

-- The occurrence covering line:col, or nil.
function M.at(index, line, col)
  for _, o in ipairs(index) do
    if o.line == line and o.col <= col and col < o.end_col then return o end
    if o.line > line then return nil end
  end
  return nil
end

return M
