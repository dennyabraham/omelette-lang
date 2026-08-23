(function () {
  var F = window.fengari;
  var L = F.lauxlib.luaL_newstate();
  F.lualib.luaL_openlibs(L);
  var out = document.getElementById("output");

  // load the browser bundle (sets up package.preload + the embedded-std searcher)
  fetch("omelette-browser.lua").then(function (r) { return r.text(); }).then(function (src) {
    if (F.lauxlib.luaL_dostring(L, F.to_luastring(src)) !== F.lua.LUA_OK) {
      out.textContent = "failed to load compiler: " + F.lua.lua_tojsstring(L, -1);
      return;
    }
    out.textContent = "Ready. Press Run.";
  });

  // set the Lua global __src to the editor contents, run a fixed driver, read __out
  function drive(driver) {
    var editorSrc = document.getElementById("editor").value;
    F.lua.lua_pushstring(L, F.to_luastring(editorSrc));
    F.lua.lua_setglobal(L, F.to_luastring("__src"));
    if (F.lauxlib.luaL_dostring(L, F.to_luastring(driver)) !== F.lua.LUA_OK) {
      out.textContent = "internal error: " + F.lua.lua_tojsstring(L, -1);
      return;
    }
    F.lua.lua_getglobal(L, F.to_luastring("__out"));
    out.textContent = F.lua.lua_tojsstring(L, -1) || "";
    F.lua.lua_pop(L, 1);
  }

  var RUN = [
    "local c = require('omelette.compiler')",
    "local buf, oldprint = {}, print",
    "print = function(...) local t={} for i=1,select('#',...) do t[i]=tostring((select(i,...))) end buf[#buf+1]=table.concat(t,'\\t') end",
    "local mod, err = c.eval(__src)",
    "print = oldprint",
    "if err then __out = '[error] '..tostring(err.message) else __out = table.concat(buf, '\\n') end",
  ].join("\n");

  var LUA = "local lua, err = require('omelette.compiler').compile(__src); __out = lua or ('[error] '..(err and err.message or '?'))";

  var CHECK = [
    "local d, err = require('omelette.compiler').check(__src)",
    "if err then __out = '[error] '..tostring(err.message)",
    "elseif #d == 0 then __out = 'No type errors.'",
    "else local t={} for i,x in ipairs(d) do t[i]=x.message end __out = table.concat(t, '\\n') end",
  ].join("\n");

  document.getElementById("run").onclick = function () { drive(RUN); };
  document.getElementById("lua").onclick = function () { drive(LUA); };
  document.getElementById("check").onclick = function () { drive(CHECK); };
})();
