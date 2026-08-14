local h = require("spec.support.harness")
local dt = require("spec.support.doctest")

local fh = io.open("docs/guide.md", "r")
local md = assert(fh, "docs/guide.md must exist"):read("*a")
fh:close()

h.describe("docs/guide.md examples run", function()
  local blocks = dt.extract(md)
  h.it("the guide has runnable examples", function() h.truthy(#blocks > 0) end)
  for _, b in ipairs(blocks) do
    h.it("guide.md line " .. b.line .. " (" .. b.mode .. ")", function()
      local ok, detail = dt.run_block(b)
      if not ok then error(detail, 2) end
    end)
  end
end)
