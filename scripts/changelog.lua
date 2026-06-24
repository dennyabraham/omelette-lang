-- Extract a version's section from a Keep-a-Changelog document.
local M = {}

-- extract(text, version) -> the lines under `## [version]` up to the next `## [` (or EOF)
function M.extract(text, version)
  local lines, capturing, out = {}, false, {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  local header = "## %[" .. version:gsub("%.", "%%.") .. "%]"
  for _, line in ipairs(lines) do
    if line:match("^## %[") then
      if capturing then break end
      if line:match("^" .. header) then capturing = true end
    elseif capturing then
      out[#out + 1] = line
    end
  end
  if not capturing then return nil end
  -- trim leading/trailing blank lines
  while out[1] == "" do table.remove(out, 1) end
  while out[#out] == "" do table.remove(out) end
  if #out == 0 then return nil end
  return table.concat(out, "\n")
end

-- run directly: `luajit scripts/changelog.lua VERSION < CHANGELOG.md` (prints the section)
if arg and arg[0] and arg[0]:find("changelog") and arg[1] then
  local text = io.read("*a") or ""
  local s = M.extract(text, arg[1])
  if not s then io.stderr:write("no changelog section for " .. arg[1] .. "\n"); os.exit(1) end
  io.write(s .. "\n")
  os.exit(0)
end

return M
