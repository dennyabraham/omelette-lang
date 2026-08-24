local h = require("spec.support.harness")

-- Render the @VERSION@/@TAG@ template, then load it as a Lua chunk in a sandbox and read
-- the globals a rockspec sets (package/version/build/...). Portable across 5.1 (setfenv)
-- and 5.4 (load with an env argument).
local function load_rockspec()
  local fh = assert(io.open("rockspecs/omelette.rockspec.template", "r"))
  local src = fh:read("*a"); fh:close()
  src = src:gsub("@VERSION@", "0.1.0"):gsub("@TAG@", "v0.1.0")
  -- __index = _G so the rockspec can reach any stdlib it references; assignments still
  -- land in `env`, so the rockspec's globals (package/version/build/...) are captured there.
  local env = setmetatable({}, { __index = _G })
  if setfenv then
    local chunk = assert(loadstring(src, "rockspec"))
    setfenv(chunk, env); chunk()
  else
    local chunk = assert(load(src, "rockspec", "t", env))
    chunk()
  end
  return env
end

h.describe("rockspec template", function()
  local rock = load_rockspec()

  h.it("renders the version and tag", function()
    h.eq(rock.version, "0.1.0-1")
    h.eq(rock.source.tag, "v0.1.0")
  end)

  h.it("uses a command build that compiles std via build-std", function()
    h.eq(rock.build.type, "command")
    h.truthy(rock.build.build_command:find("build/build%-std.lua"))
  end)

  h.it("installs the omelette modules (glob covers typecheck), std, and the binary", function()
    local inst = rock.build.install_command
    h.truthy(inst:find("omelette/%*.lua"))     -- all omelette/*.lua incl. typecheck.lua
    h.truthy(inst:find("build%-out/std"))       -- the compiled std modules
    h.truthy(inst:find("bin/omelette"))         -- the CLI entry point
    h.truthy(inst:find("%$%(LUADIR%)"))         -- into LuaRocks' Lua module dir
    h.truthy(inst:find("%$%(BINDIR%)"))         -- and its binary dir
  end)
end)
