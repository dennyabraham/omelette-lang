local h = require("spec.support.harness")
local amalg = require("build.amalgamate")

h.describe("amalgamate", function()
  h.it("bundles every module as a package.preload entry plus a bootstrap", function()
    local out = amalg.build()
    h.truthy(out:find('package.preload%["omelette.lexer"%]'))
    h.truthy(out:find('package.preload%["omelette.codegen"%]'))
    h.truthy(out:find('package.preload%["omelette"%]'))      -- init.lua
    h.truthy(out:find('require%("omelette.cli"%).main'))     -- bootstrap
    h.truthy(out:find("^#!/usr/bin/env lua"))                -- shebang
  end)
  h.it("the bundled module bodies are present (e.g. the lexer's tokenize)", function()
    local out = amalg.build()
    h.truthy(out:find("function M.tokenize"))
  end)
end)
