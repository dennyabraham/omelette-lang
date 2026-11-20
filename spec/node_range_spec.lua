local h = require("spec.support.harness")
local parser = require("omelette.parser")
local dt = require("spec.support.doctest")

local function range(n) return { n.start_line, n.start_col, n.end_line, n.end_col } end

local function before_or_at(l1, c1, l2, c2)
  return l1 < l2 or (l1 == l2 and c1 <= c2)
end

local function describe_node(n)
  return string.format("%s %s:%s-%s:%s", tostring(n.kind), tostring(n.start_line),
    tostring(n.start_col), tostring(n.end_line), tostring(n.end_col))
end

-- Checks every table with a `kind` under `node`; `parent` is the nearest enclosing node.
local function check_tree(node, parent, where, problems)
  if type(node) ~= "table" then return end
  local enclosing = parent
  if node.kind ~= nil then
    local r = range(node)
    if type(r[1]) ~= "number" or type(r[2]) ~= "number"
        or type(r[3]) ~= "number" or type(r[4]) ~= "number" then
      problems[#problems + 1] = where .. ": no range on " .. describe_node(node)
    elseif not before_or_at(r[1], r[2], r[3], r[4]) then
      problems[#problems + 1] = where .. ": end before start on " .. describe_node(node)
    elseif parent and not (before_or_at(parent.start_line, parent.start_col, r[1], r[2])
        and before_or_at(r[3], r[4], parent.end_line, parent.end_col)) then
      problems[#problems + 1] = where .. ": " .. describe_node(node)
        .. " outside " .. describe_node(parent)
    end
    enclosing = node
  end
  for _, child in pairs(node) do check_tree(child, enclosing, where, problems) end
end

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function sources()
  local out = {}
  local handle = io.popen("ls std/*.egg spec/fixtures/*.egg")
  for path in handle:lines() do out[#out + 1] = { where = path, code = read(path) } end
  handle:close()
  for _, b in ipairs(dt.extract(read("docs/guide.md"))) do
    out[#out + 1] = { where = "docs/guide.md:" .. b.line, code = b.code }
  end
  return out
end

h.describe("node ranges", function()
  h.it("a binop spans its operands and keeps its operator position", function()
    local prog = assert(parser.parse("1 + 2 * 3"))
    local e = prog.stmts[1]
    h.eq(e.kind, "binop")
    h.eq(range(e), { 1, 1, 1, 10 })
    h.eq({ e.line, e.col }, { 1, 3 })
  end)
  h.it("a postfix chain spans from its first token", function()
    local prog = assert(parser.parse("f(x)[1].y"))
    local e = prog.stmts[1]
    h.eq(e.kind, "field")
    h.eq(range(e), { 1, 1, 1, 10 })
  end)
  h.it("every node in the repository's Omelette code has a range inside its parent's", function()
    local problems, parsed = {}, 0
    for _, s in ipairs(sources()) do
      local prog = parser.parse(s.code)
      if prog then
        parsed = parsed + 1
        check_tree(prog, nil, s.where, problems)
      end
    end
    h.truthy(parsed > 10)
    if #problems > 0 then
      error(#problems .. " problems, first: " .. table.concat(problems, "\n  ", 1, math.min(#problems, 10)))
    end
  end)
end)
