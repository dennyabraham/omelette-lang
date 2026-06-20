local M = {}
local failures, total = {}, 0
local current = "<root>"

local function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function render(v)
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for k, val in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. render(val) end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function M.describe(name, fn) current = name; fn() end

function M.it(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if not ok then failures[#failures + 1] = current .. " > " .. name .. ": " .. tostring(err) end
end

function M.eq(a, b)
  if not deep_eq(a, b) then error("expected " .. render(b) .. " got " .. render(a), 2) end
end

function M.truthy(v) if not v then error("expected truthy, got " .. tostring(v), 2) end end

function M.throws(fn) return not (pcall(fn)) end

function M.run()
  io.write(string.format("\n%d tests, %d failures\n", total, #failures))
  for _, f in ipairs(failures) do io.write("  FAIL " .. f .. "\n") end
  return #failures == 0
end

return M
