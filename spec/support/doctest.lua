local compiler = require("omelette.compiler")
local M = {}

local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

-- extract fenced code blocks; pair an `egg` block with an immediately-following
-- `output`/`error` fence, else it is smoke.
function M.extract(md)
  local lines = {}
  for line in (md .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  -- 1) tokenize every fenced block: { info, code, line }
  local fences, i = {}, 1
  while i <= #lines do
    local info = lines[i]:match("^```(%a*)%s*$")
    if info ~= nil then
      local start_line, body = i, {}
      i = i + 1
      while i <= #lines and not lines[i]:match("^```%s*$") do
        body[#body + 1] = lines[i]; i = i + 1
      end
      fences[#fences + 1] = { info = info, code = table.concat(body, "\n"), line = start_line }
      i = i + 1  -- skip the closing ```
    else
      i = i + 1
    end
  end
  -- 2) pair egg blocks with a following output/error fence
  local blocks, j = {}, 1
  while j <= #fences do
    local f = fences[j]
    if f.info == "egg" then
      local nxt = fences[j + 1]
      if nxt and (nxt.info == "output" or nxt.info == "error") then
        blocks[#blocks + 1] = { code = f.code, mode = nxt.info, expect = nxt.code, line = f.line }
        j = j + 2
      else
        blocks[#blocks + 1] = { code = f.code, mode = "smoke", expect = nil, line = f.line }
        j = j + 1
      end
    else
      j = j + 1
    end
  end
  return blocks
end

-- run `code` through compiler.eval while capturing print; returns ok, errmsg, output
local function eval_capturing(code)
  local buf, old = {}, _G.print
  _G.print = function(...)
    local parts, n = {}, select("#", ...)
    for k = 1, n do parts[k] = tostring((select(k, ...))) end
    buf[#buf + 1] = table.concat(parts, "\t")
  end
  local ok, mod, err = pcall(compiler.eval, code)
  _G.print = old
  if not ok then return false, tostring(mod), table.concat(buf, "\n") end   -- Lua runtime error
  if err then return false, tostring(err.message), table.concat(buf, "\n") end -- compile diagnostic
  return true, nil, table.concat(buf, "\n")
end

function M.run_block(block)
  if block.mode == "error" then
    local diags, err = compiler.check(block.code)
    if err then
      if err.message:find(block.expect, 1, true) then return true end
      return false, "line " .. tostring(block.line) .. ": parse error did not contain '"
        .. block.expect .. "': " .. err.message
    end
    if not diags or #diags == 0 then
      return false, "line " .. tostring(block.line) .. ": expected a diagnostic containing '"
        .. block.expect .. "', but it checked clean"
    end
    for _, d in ipairs(diags) do
      if d.message:find(block.expect, 1, true) then return true end
    end
    return false, "line " .. tostring(block.line) .. ": no diagnostic contained '"
      .. block.expect .. "'; got: " .. diags[1].message
  end

  local ok, errmsg, out = eval_capturing(block.code)
  if block.mode == "smoke" then
    if not ok then return false, "line " .. tostring(block.line) .. ": expected clean run, got: " .. tostring(errmsg) end
    return true
  elseif block.mode == "output" then
    if not ok then return false, "line " .. tostring(block.line) .. ": run error: " .. tostring(errmsg) end
    if trim(out) ~= trim(block.expect) then
      return false, "line " .. tostring(block.line) .. ": output mismatch\n  expected: ["
        .. trim(block.expect) .. "]\n  got:      [" .. trim(out) .. "]"
    end
    return true
  end
  return false, "unknown mode " .. tostring(block.mode)
end

return M
