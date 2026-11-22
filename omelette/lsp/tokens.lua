-- Semantic tokens: lexer classes first, then the syntax tree reclassifies identifiers
-- by what they name. Statements that failed to parse keep the lexer's classes.
local M = {}

M.LEGEND = {
  tokenTypes = { "keyword", "string", "number", "comment", "operator", "type",
                 "enumMember", "function", "parameter", "property", "variable" },
  tokenModifiers = { "declaration" },
}

local INDEX = {}
for i, name in ipairs(M.LEGEND.tokenTypes) do INDEX[name] = i - 1 end

local LEXER_CLASS = { keyword = "keyword", string = "string", number = "number",
                      op = "operator", ident = "variable" }

local function key(line, col) return line .. ":" .. col end

-- Walks every table under node, recording the class of identifiers it names.
local function classify(node, out, seen)
  if type(node) ~= "table" or seen[node] then return end
  seen[node] = true
  local function mark(tok, class, decl)
    if tok then out[key(tok.line, tok.col)] = { class = class, decl = decl } end
  end
  local function mark_start(n, class, decl)
    out[key(n.start_line, n.start_col)] = { class = class, decl = decl }
  end
  local k = node.kind
  if k == "let" then
    mark(node.name_tok, node.param_toks and "function" or "variable", true)
    for _, t in ipairs(node.param_toks or {}) do mark(t, "parameter", true) end
  elseif k == "lambda" then
    for _, t in ipairs(node.param_toks or {}) do mark(t, "parameter", true) end
  elseif k == "type_decl" then
    mark(node.name_tok, "type", true)
    for _, v in ipairs(node.variants) do mark(v.name_tok, "enumMember", true) end
  elseif k == "type_name" then
    mark_start(node, "type", false)
  elseif k == "construct" or k == "ctor_pat" then
    mark_start(node, "enumMember", false)
  elseif k == "field" then
    mark(node.name_tok, "property", false)
  elseif k == "var" then
    mark_start(node, "variable", true)
  elseif k == "generator" then
    mark(node.name_tok, "variable", true)
    mark(node.value_name_tok, "variable", true)
  end
  if node.key_tok then mark(node.key_tok, "property", false) end
  for field, child in pairs(node) do
    if type(child) == "table" and field ~= "name_tok" and field ~= "key_tok"
        and field ~= "value_name_tok" and field ~= "param_toks" then
      classify(child, out, seen)
    end
  end
end

-- Adds one row per line that the span [line:col, end_line:end_col) covers.
local function add_span(rows, pos, line, col, end_line, end_col, class, decl)
  for l = line, end_line do
    local c1 = (l == line) and col or 1
    local c2 = (l == end_line) and end_col or pos:line_end(l)
    if c2 > c1 then
      local p = pos:to_lsp(l, c1)
      rows[#rows + 1] = { p.line, p.character, pos:length(l, c1, c2), INDEX[class], decl and 1 or 0 }
    end
  end
end

-- index (optional) is a list of name occurrences (lsp/names.lua); a use of a name takes
-- the class of its declaration.
function M.encode(parsed, pos, index)
  local names = {}
  classify(parsed.program, names, {})
  for _, o in ipairs(index or {}) do
    if not o.is_decl then names[key(o.line, o.col)] = { class = o.decl.kind, decl = false } end
  end
  local rows = {}
  for _, t in ipairs(parsed.tokens) do
    local class = LEXER_CLASS[t.type]
    if class then
      local decl = false
      if t.type == "ident" then
        local n = names[key(t.line, t.col)]
        if n then class, decl = n.class, n.decl end
      end
      add_span(rows, pos, t.line, t.col, t.end_line, t.end_col, class, decl)
    end
  end
  for _, c in ipairs(parsed.comments) do
    add_span(rows, pos, c.line, c.col, c.end_line, c.end_col, "comment", false)
  end
  table.sort(rows, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
  local data, prev_line, prev_char = {}, 0, 0
  for _, r in ipairs(rows) do
    local dl = r[1] - prev_line
    data[#data + 1] = dl
    data[#data + 1] = dl == 0 and r[2] - prev_char or r[2]
    data[#data + 1] = r[3]
    data[#data + 1] = r[4]
    data[#data + 1] = r[5]
    prev_line, prev_char = r[1], r[2]
  end
  return data
end

return M
