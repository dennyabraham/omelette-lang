local h = require("spec.support.harness")
local rpc = require("omelette.lsp.rpc")

-- An input over a string, supporting the two reads rpc.read uses.
local function input(s)
  local pos = 1
  return {
    read = function(_, fmt)
      if pos > #s then return nil end
      if fmt == "*l" then
        local nl = s:find("\n", pos, true)
        local line = s:sub(pos, (nl or #s + 1) - 1)
        pos = (nl or #s) + 1
        return line
      end
      local chunk = s:sub(pos, pos + fmt - 1)
      pos = pos + #chunk
      return chunk
    end,
  }
end

local function output()
  local buf = {}
  return { write = function(_, ...) for _, v in ipairs({ ... }) do buf[#buf + 1] = v end end,
           flush = function() end, text = function() return table.concat(buf) end }
end

local function frame(body) return "Content-Length: " .. #body .. "\r\n\r\n" .. body end

h.describe("lsp rpc", function()
  h.it("reads one message", function()
    local m = assert(rpc.read(input(frame('{"id":1,"method":"x"}'))))
    h.eq(m.id, 1)
    h.eq(m.method, "x")
  end)
  h.it("reads two messages back to back", function()
    local inp = input(frame('{"id":1}') .. frame('{"id":2}'))
    h.eq(rpc.read(inp).id, 1)
    h.eq(rpc.read(inp).id, 2)
  end)
  h.it("ignores other headers", function()
    local body = '{"id":3}'
    local s = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: "
      .. #body .. "\r\n\r\n" .. body
    h.eq(rpc.read(input(s)).id, 3)
  end)
  h.it("counts the body length in bytes", function()
    local m = assert(rpc.read(input(frame('{"t":"é"}') .. frame('{"id":4}'))))
    h.eq(m.t, "é")
  end)
  h.it("reports a bad body and stays aligned with the next message", function()
    local inp = input(frame("{bad") .. frame('{"id":5}'))
    local m, err = rpc.read(inp)
    h.eq(m, nil)
    h.truthy(err:find("^parse error"))
    h.eq(rpc.read(inp).id, 5)
  end)
  h.it("returns eof at the end of input", function()
    local m, err = rpc.read(input(""))
    h.eq(m, nil)
    h.eq(err, "eof")
  end)
  h.it("writes a message that reads back", function()
    local out = output()
    rpc.write(out, { id = 6, result = "é" })
    local text = out.text()
    h.truthy(text:find("^Content%-Length: 22\r\n\r\n"))
    h.eq(rpc.read(input(text)).result, "é")
  end)
end)
