local compiler = require("omelette.compiler")
local searcher = require("omelette.searcher")
return {
  version = "0.3.1",
  compile = compiler.compile,
  eval = compiler.eval,
  install = searcher.install,
}
