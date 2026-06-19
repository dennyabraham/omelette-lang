local compiler = require("omelette.compiler")
local errors = require("omelette.errors")
local M = {}

function M.new_session() return { preamble = {} } end

-- A line is evaluated by building a throwaway program: prior `let`s + this line
-- exported as `pub let __result = <line>` when the line is an expression, or the
-- new binding appended to the preamble when it is a `let`.
function M.eval_line(line, session)
  session = session or M.new_session()
  local trimmed = line:gsub("^%s+", "")
  local is_let = trimmed:match("^let ") or trimmed:match("^pub ")

  local body
  if is_let then
    body = table.concat(session.preamble, "\n") .. "\n" .. line
  else
    body = table.concat(session.preamble, "\n") .. "\npub let __result = " .. line
  end

  local mod, err = compiler.eval(body, "repl")
  if err then return nil, err, session end

  if is_let then
    session.preamble[#session.preamble + 1] = line
    return nil, nil, session
  end
  return mod.__result, nil, session
end

function M.start()
  io.write("omelette repl — Ctrl-D to exit\n")
  local session = M.new_session()
  while true do
    io.write("> ")
    local line = io.read("*l")
    if not line then break end
    local result, err
    result, err, session = M.eval_line(line, session)
    if err then
      io.write(errors.render(err) .. "\n")
    elseif result ~= nil then
      io.write(tostring(result) .. "\n")
    end
  end
  return 0
end

return M
