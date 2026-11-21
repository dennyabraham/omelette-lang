local h = require("spec.support.harness")
local json = require("omelette.json")

local INTERP = (arg and arg[-1]) or "lua"

local function frame(m)
  local body = json.encode(m)
  return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- Runs `omelette lsp` with the given messages on stdin; returns stdout and the exit code.
-- The code goes through the shell, because LuaJIT's popen:close does not return it.
local function run(messages)
  local out, code = os.tmpname(), os.tmpname()
  local p = io.popen('"' .. INTERP .. '" bin/omelette lsp > "' .. out .. '"; echo $? > "' .. code .. '"', "w")
  for _, m in ipairs(messages) do p:write(frame(m)) end
  p:close()
  local result = { out = read(out), code = tonumber(read(code):match("%d+")) }
  os.remove(out)
  os.remove(code)
  return result
end

h.describe("omelette lsp (subprocess)", function()
  h.it("initializes, shuts down and exits 0", function()
    local r = run({
      { jsonrpc = "2.0", id = 1, method = "initialize", params = { capabilities = {} } },
      { jsonrpc = "2.0", method = "initialized", params = {} },
      { jsonrpc = "2.0", id = 2, method = "shutdown" },
      { jsonrpc = "2.0", method = "exit" },
    })
    h.truthy(r.out:find('"id":1'))
    h.truthy(r.out:find('"id":2'))
    h.eq(r.code, 0)
  end)
  h.it("exits 1 when stdin closes without exit", function()
    local r = run({ { jsonrpc = "2.0", id = 1, method = "initialize", params = { capabilities = {} } } })
    h.eq(r.code, 1)
  end)
end)
