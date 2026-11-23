-- Document symbols: the file's top-level lets and type declarations, as an outline.
local json = require("omelette.json")
local M = {}

local FUNCTION, VARIABLE, ENUM, ENUM_MEMBER = 12, 13, 10, 22

local function range(pos, n)
  return { start = pos:to_lsp(n.start_line or n.line, n.start_col or n.col),
           ["end"] = pos:to_lsp(n.end_line, n.end_col) }
end

local function symbol(pos, name, kind, node, name_at, children)
  return { name = name, kind = kind, range = range(pos, node), selectionRange = range(pos, name_at),
           children = json.array(children or {}) }
end

local function pattern_vars(pat, out)
  if pat.kind == "var" then out[#out + 1] = pat; return end
  for _, list in ipairs({ pat.elems or {}, pat.args or {} }) do
    for _, p in ipairs(list) do pattern_vars(p, out) end
  end
  for _, f in ipairs(pat.fields or {}) do if type(f) == "table" and f.pat then pattern_vars(f.pat, out) end end
end

function M.document(program, pos)
  local out = json.array({})
  for _, node in ipairs(program.stmts) do
    if node.kind == "let" and node.pattern then
      local vars = {}
      pattern_vars(node.pattern, vars)
      for _, v in ipairs(vars) do out[#out + 1] = symbol(pos, v.name, VARIABLE, node, v) end
    elseif node.kind == "let" and node.name_tok then
      out[#out + 1] = symbol(pos, node.name, node.params and FUNCTION or VARIABLE, node, node.name_tok)
    elseif node.kind == "type_decl" then
      local members = {}
      for _, v in ipairs(node.variants) do
        members[#members + 1] = symbol(pos, v.name, ENUM_MEMBER, v, v.name_tok)
      end
      out[#out + 1] = symbol(pos, node.name, ENUM, node, node.name_tok, members)
    end
  end
  return out
end

return M
