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
  h.it("play.html loads fengari + play.js, and play.js fetches the bundle", function()
    site.build()
    local function slurp(p) local fh = assert(io.open(p, "r")); local s = fh:read("*a"); fh:close(); return s end
    local html = slurp("site/dist/play.html")
    h.truthy(html:find("fengari%-web%.js"))        -- the Lua VM
    h.truthy(html:find("play%.js"))                -- the wiring
    -- the bundle is fetched by play.js (not referenced in the HTML)
    h.truthy(slurp("site/dist/play.js"):find('fetch%("omelette%-browser%.lua"'))
  end)
end)
