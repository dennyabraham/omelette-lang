local h = require("spec.support.harness")
local cv = require("scripts.check-version")
local cl = require("scripts.changelog")

h.describe("check-version", function()
  h.it("accepts a matching vX.Y.Z tag", function()
    local ok = cv.check("v1.2.3", "1.2.3")
    h.truthy(ok)
  end)
  h.it("rejects a mismatched tag", function()
    local ok, msg = cv.check("v1.2.3", "1.2.4")
    h.truthy(not ok)
    h.truthy(msg:find("1.2.4"))
  end)
  h.it("rejects a malformed tag", function()
    h.truthy(not (cv.check("1.2.3", "1.2.3")))   -- missing leading v
    h.truthy(not (cv.check("vx", "1.2.3")))
  end)
  h.it("reads the version out of an init.lua-style string via a temp file", function()
    local p = os.tmpname()
    local fh = io.open(p, "w"); fh:write('return {\n  version = "9.8.7",\n}\n'); fh:close()
    h.eq(cv.read_init_version(p), "9.8.7")
    os.remove(p)
  end)
end)

h.describe("changelog", function()
  local sample = table.concat({
    "# Changelog",
    "",
    "## [1.1.0]",
    "- added b",
    "",
    "## [1.0.0]",
    "- initial",
  }, "\n")
  h.it("extracts a version's section", function()
    local s = cl.extract(sample, "1.1.0")
    h.truthy(s:find("added b"))
    h.truthy(not s:find("initial"))
  end)
  h.it("extracts the last version's section", function()
    h.truthy(cl.extract(sample, "1.0.0"):find("initial"))
  end)
  h.it("returns nil for a missing version", function()
    h.eq(cl.extract(sample, "9.9.9"), nil)
  end)
end)
