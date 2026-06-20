local compiler = require("omelette.compiler")
local errors = require("omelette.errors")
local lexer = require("omelette.lexer")
local parser = require("omelette.parser")
local M = {}

local USAGE = "usage: omelette <build|run|repl> [file.egg] [--out path] [--ast] [--tokens]\n"

local function read_file(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local data = fh:read("*a"); fh:close()
  return data
end

local function has_flag(argv, name)
  for _, a in ipairs(argv) do if a == name then return true end end
  return false
end

local function flag_value(argv, name)
  for i, a in ipairs(argv) do if a == name then return argv[i + 1] end end
  return nil
end

local function cmd_build(argv)
  local file = argv[2]
  local src = file and read_file(file)
  if not src then
    io.write(errors.render(errors.new("cannot read file '" .. tostring(file) .. "'", 1, 1)) .. "\n")
    return 1
  end
  if has_flag(argv, "--tokens") then
    local toks, terr = lexer.tokenize(src)
    if not toks then io.write(errors.render(terr) .. "\n"); return 1 end
    for _, t in ipairs(toks) do io.write(t.type .. " " .. tostring(t.value) .. "\n") end
    return 0
  end
  if has_flag(argv, "--ast") then
    local prog, perr = parser.parse(src)
    if not prog then io.write(errors.render(perr) .. "\n"); return 1 end
    io.write("program with " .. #prog.stmts .. " statements\n")
    return 0
  end
  local lua, err = compiler.compile(src)
  if not lua then io.write(errors.render(err) .. "\n"); return 1 end
  local out = flag_value(argv, "--out")
  if out then
    local fh = io.open(out, "w")
    if not fh then io.write(errors.render(errors.new("cannot write file '" .. tostring(out) .. "'", 1, 1)) .. "\n"); return 1 end
    fh:write(lua); fh:close()
  else
    io.write(lua .. "\n")
  end
  return 0
end

local function cmd_run(argv)
  local file = argv[2]
  local src = file and read_file(file)
  if not src then
    io.write(errors.render(errors.new("cannot read file '" .. tostring(file) .. "'", 1, 1)) .. "\n")
    return 1
  end
  local _, err = compiler.eval(src, file)
  if err then io.write(errors.render(err) .. "\n"); return 1 end
  return 0
end

function M.main(argv)
  local cmd = argv[1]
  if cmd == "build" then return cmd_build(argv) end
  if cmd == "run" then return cmd_run(argv) end
  if cmd == "repl" then return require("omelette.repl").start() end
  io.write(USAGE)
  return 2
end

return M
