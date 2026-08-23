local h = require("spec.support.harness")
local site = require("site.build")

h.describe("site build", function()
  h.it("build() writes the expected files into site/dist", function()
    site.build()
    local expected = {
      "site/dist/index.html", "site/dist/guide.html", "site/dist/play.html",
      "site/dist/style.css", "site/dist/play.js", "site/dist/guide.md",
      "site/dist/omelette-browser.lua",
      "site/dist/fengari-web.js", "site/dist/marked.min.js",
    }
    for _, path in ipairs(expected) do
      local fh = io.open(path, "r")
      h.truthy(fh ~= nil)  -- missing: build did not produce this file
      if fh then fh:close() end
    end
  end)
  h.it("the built play.html references the bundle and fengari", function()
    site.build()
    local fh = assert(io.open("site/dist/play.html", "r")); local s = fh:read("*a"); fh:close()
    h.truthy(s:find("omelette%-browser%.lua"))
    h.truthy(s:find("fengari%-web%.js"))
  end)
end)
