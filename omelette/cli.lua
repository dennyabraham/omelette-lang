local compiler = require("omelette.compiler")
local errors = require("omelette.errors")
local lexer = require("omelette.lexer")
local parser = require("omelette.parser")
local M = {}

local USAGE = "usage: omelette <build|run|check|repl> [file.egg] [--out path] [--ast] [--tokens] [--no-check]\n"

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

-- the positional file argument: the first non-flag arg after the command (argv[1]),
-- skipping any "--flag" and the value that follows "--out". This makes flag order
-- irrelevant (e.g. `build --no-check foo.egg` and `build foo.egg --no-check` both work).
local function positional_file(argv)
  local i = 2
  while argv[i] do
    if argv[i] == "--out" then
      i = i + 2            -- skip the flag and its value
    elseif argv[i]:sub(1, 2) == "--" then
      i = i + 1            -- skip a valueless flag
    else
      return argv[i]
    end
  end
  return nil
end

local function cmd_build(argv)
  local file = positional_file(argv)
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
  local lua, err = compiler.compile(src, { check = not has_flag(argv, "--no-check") })
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
  local file = positional_file(argv)
  local src = file and read_file(file)
  if not src then
    io.write(errors.render(errors.new("cannot read file '" .. tostring(file) .. "'", 1, 1)) .. "\n")
    return 1
  end
  -- install the .egg require-hook so the program can `require("std.list")` and
  -- sibling .egg modules (resolved relative to the current directory)
  require("omelette.searcher").install()
  local lua, cerr = compiler.compile(src, { check = not has_flag(argv, "--no-check") })
  if not lua then io.write(errors.render(cerr) .. "\n"); return 1 end
  local _, err = compiler.eval(src, file)   -- eval re-compiles without check; fine (already validated)
  if err then io.write(errors.render(err) .. "\n"); return 1 end
  return 0
end

local function cmd_check(argv)
  local file = positional_file(argv)
  local src = file and read_file(file)
  if not src then
    io.write(errors.render(errors.new("cannot read file '" .. tostring(file) .. "'", 1, 1)) .. "\n")
    return 1
  end
  local diags, err = compiler.check(src)
  if err then io.write(errors.render(err) .. "\n"); return 1 end
  if #diags == 0 then io.write("no type errors\n"); return 0 end
  for _, d in ipairs(diags) do io.write(errors.render(d) .. "\n") end
  return 1
end

function M.main(argv)
  local cmd = argv[1]
  if cmd == "build" then return cmd_build(argv) end
  if cmd == "run" then return cmd_run(argv) end
  if cmd == "check" then return cmd_check(argv) end
  if cmd == "repl" then return require("omelette.repl").start() end
  io.write(USAGE)
  return 2
end

return M
