package.path = "./?.lua;./?/init.lua;" .. package.path
local h = require("spec.support.harness")

-- discover spec files via Lua's io.popen (portable enough for dev use)
local handle = io.popen('ls spec/*_spec.lua')
for line in handle:lines() do
  local mod = line:gsub("%.lua$", ""):gsub("/", ".")
  require(mod)
end
handle:close()

os.exit(h.run() and 0 or 1)
