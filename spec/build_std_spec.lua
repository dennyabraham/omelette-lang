local h = require("spec.support.harness")
local bs = require("build.build-std")

local function loads(lua)
  local f = (loadstring or load)(lua)
  return f ~= nil
end

h.describe("build-std (compile std/*.egg at build time)", function()
  h.it("STD lists the three stdlib modules", function()
    h.eq(table.concat(bs.STD, ","), "std.list,std.string,std.table")
  end)

  h.it("compile_all returns one loadable Lua chunk per module", function()
    local all = bs.compile_all()
    h.eq(#all, 3)
    for _, m in ipairs(all) do
      h.truthy(m.lua:find("return M"))   -- each std module ends in `return M`
      h.truthy(loads(m.lua))             -- and the emitted Lua parses
    end
  end)

  h.it("preload_block emits a loadable package.preload entry per module", function()
    local block = bs.preload_block()
    h.truthy(block:find('package.preload%["std.list"%] = function'))
    h.truthy(block:find('package.preload%["std.string"%] = function'))
    h.truthy(block:find('package.preload%["std.table"%] = function'))
    h.truthy(loads(block))               -- the whole block is valid Lua
  end)

  h.it("a missing module raises (a broken build must fail loudly)", function()
    h.truthy(h.throws(function() bs.compile("std.nope") end))
  end)

  h.it("write_lua writes one std/<leaf>.lua per module", function()
    local dir = os.tmpname() .. "_std"
    local paths = bs.write_lua(dir)
    h.eq(#paths, 3)
    local fh = assert(io.open(dir .. "/std/list.lua", "r"))
    local body = fh:read("*a"); fh:close()
    h.truthy(body:find("return M"))
    os.execute('rm -rf "' .. dir .. '"')
  end)
end)
