# LSP Server and Neovim Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `omelette lsp`, a language server with diagnostics and semantic tokens, released in omelette 0.2.0, and the `omelette.nvim` plugin that starts it.

**Architecture:** The server has four parts, each in its own file: JSON, message framing, positions with semantic tokens, and the server loop. They sit on `parser.parse_all` and the type checker from sub-project 1. The parser gains references to the tokens of declared names, so that semantic tokens can classify them. The plugin is four small files in a separate repository.

**Tech Stack:** Lua 5.1 / LuaJIT / Lua 5.4, with no dependencies. Neovim 0.11+ for the plugin.

**Spec:** `docs/superpowers/specs/2026-11-20-lsp-server-design.md`

## Abstract

Eight tasks. Tasks 1–7 are in `omelette-lang`, on one branch and one PR. Task 7 bumps the version to 0.2.0, so merging that PR tags and publishes the release (`tag-on-version-bump.yml`). Task 8 is in `omelette.nvim`, on its own PR, and is merged after 0.2.0 is on LuaRocks.

The spec left one point unconfirmed: that Neovim links every standard `@lsp.type.*` group. I checked it on Neovim 0.12.6: all 11 token types in the legend link to a default group, so the plugin needs no highlight links. `@lsp.mod.declaration` has no link, which is fine, because a modifier only adds to the type's highlight.

Two deferred issues are part of this plan:
- #43 (the CHANGELOG note and tests for the lexer's changed line numbers): Tasks 3 and 7.
- #44 (stack overflow on very deep nesting): Task 6.

## Contents

- [Global Constraints](#global-constraints)
- [Review Focus](#review-focus)
- [Task 1: JSON](#task-1-json)
- [Task 2: Message framing](#task-2-message-framing)
- [Task 3: Diagnostic end positions](#task-3-diagnostic-end-positions)
- [Task 4: Name tokens on nodes](#task-4-name-tokens-on-nodes)
- [Task 5: Positions and semantic tokens](#task-5-positions-and-semantic-tokens)
- [Task 6: Server and `omelette lsp`](#task-6-server-and-omelette-lsp)
- [Task 7: Packaging and the 0.2.0 release](#task-7-packaging-and-the-020-release)
- [Task 8: The omelette.nvim plugin](#task-8-the-omelettenvim-plugin)

## Global Constraints

- No new rock dependency. `dependencies` stays `{ "lua >= 5.1" }`.
- Code runs on Lua 5.1, LuaJIT and Lua 5.4.
- Tests run with `luajit spec/run.lua`. Success is a last line of `N tests, 0 failures`.
- Spawned processes use `arg[-1]` as the interpreter.
- The server writes only protocol messages to stdout. Logs go through `window/logMessage`.
- The token legend, in this order: `keyword`, `string`, `number`, `comment`, `operator`, `type`, `enumMember`, `function`, `parameter`, `property`, `variable`. The one modifier is `declaration`.
- Compiler positions are 1-based byte columns. LSP positions are 0-based, in UTF-8 bytes or UTF-16 code units.

## Review Focus

1. **A file the analysis can't handle.** A document with 200,000 nested `(` (#44) must not stop the server. The user gets one diagnostic saying the file could not be checked, plus a log message, and later requests still work. Tested in Task 6.
2. **Non-ASCII text before a token under UTF-16.** `let s = "é" + x` must place `x` at character 14 (UTF-16), not 15 (bytes). Tested in Task 5.
3. **Framing variations.** A header block with a `Content-Type` line as well as `Content-Length`, and two messages back to back in one read, must both decode. Tested in Task 2.
4. **Empty results encode as arrays.** An empty document, a document of only comments, and a semantic tokens request for a URI that was never opened must give `"data":[]` and `"diagnostics":[]`, not `{}`. Tested in Tasks 1 and 6.
5. **Exit codes.** `shutdown` then `exit` gives 0. `exit` alone gives 1. The end of stdin without `exit` gives 1. Tested in Task 6.

---

### Task 1: JSON

**Files:**
- Create: `omelette/json.lua`
- Test: `spec/json_spec.lua`

**Interfaces:**
- Produces: `json.encode(value) -> string`.
- Produces: `json.decode(text) -> value | nil, err`.
- Produces: `json.null`, a unique value for JSON `null`.
- Produces: `json.array(t) -> t`, which marks `t` as an array.
- Encoding rules:
  - A table is an array if it is marked or has `t[1] ~= nil`. Any other table, including an unmarked empty one, is an object.
  - Decoded arrays are marked.
  - Whole numbers below 2^53 encode with no decimal point.
  - Strings escape `"`, `\` and control characters below 0x20 (as `\n`, `\t`, `\r`, `\b`, `\f`, or `\u00XX`). Other bytes pass through unchanged.

- [ ] **Step 1: Write the failing tests:**
  - Round trips of `{ a = 1, b = { true, false, json.null }, c = "x" }`.
  - `encode(json.array({}))` gives `[]`, and `encode({})` gives `{}`.
  - `encode(3)` gives `3`, and `encode(0.5)` gives `0.5`.
  - `encode("a\"b\\\n\1")` gives `"a\"b\\\n\u0001"`.
  - `decode('"\\u00e9"')` gives `"é"`, and `decode('"\\ud83d\\ude00"')` gives the four-byte UTF-8 for U+1F600.
  - Decoding `'[1, 2'`, `'{"a" 1}'` and `''` each returns `nil` and an error string, without throwing.
  - Decoding `'  {"a": [ ] }  '` gives a table whose `a` re-encodes as `[]`.
- [ ] **Step 2: Run.** Expected: they fail, because `omelette.json` doesn't exist.
- [ ] **Step 3: Implement** `omelette/json.lua`: a recursive-descent decoder, with errors raised internally and caught at `decode`.
- [ ] **Step 4: Run.** Expected: `0 failures`.
- [ ] **Step 5: Commit.** `feat(json): JSON encode/decode for the language server`

### Task 2: Message framing

**Files:**
- Create: `omelette/lsp/rpc.lua`
- Test: `spec/lsp_rpc_spec.lua`

**Interfaces:**
- Consumes: `json.encode` and `json.decode` (Task 1).
- Produces: `rpc.read(input) -> message | nil, err`.
  - `input` is any object with `input:read("*l")` and `input:read(n)`, such as `io.stdin`.
  - Header lines end in `\r\n`. Unknown headers are ignored.
  - At end of input it returns `nil, "eof"`. For bad JSON it returns `nil, "parse error: …"` after reading the whole body, so the next message still lines up.
- Produces: `rpc.write(output, message)`, which writes `Content-Length: N\r\n\r\n` and the body, then flushes `output`. `N` is the body's length in bytes.

- [ ] **Step 1: Write the failing tests.** Use a fake input built from a string, with `read("*l")` and `read(n)`.
  - One message.
  - Two messages back to back.
  - A header block with `Content-Type: application/vscode-jsonrpc; charset=utf-8` before `Content-Length`.
  - A body containing `é`, whose length counts bytes.
  - A bad body followed by a good message: the first read returns the parse error, and the second returns the good message.
  - End of input returns `nil, "eof"`.
  - `write` produces the exact header and body, and `read` reads it back.
- [ ] **Step 2: Run.** Expected: they fail, because the module doesn't exist.
- [ ] **Step 3: Implement** `omelette/lsp/rpc.lua`.
- [ ] **Step 4: Run.** Expected: `0 failures`.
- [ ] **Step 5: Commit.** `feat(lsp): Content-Length message framing`

### Task 3: Diagnostic end positions

**Files:**
- Modify: `omelette/errors.lua`, `omelette/lexer.lua`, `omelette/parser.lua` (`Parser:fail`), `omelette/typecheck.lua` (both `errors.new` calls)
- Test: `spec/errors_spec.lua`, `spec/lexer_editor_spec.lua`, `spec/parse_all_spec.lua`, `spec/typecheck_spec.lua` (or the spec file that already covers `'n' is declared number but assigned string`)

**Interfaces:**
- Produces: `errors.new(message, line, col, source, end_line, end_col)`. With no end given, `end_line` is `line` and `end_col` is `col + 1`. `render` doesn't change.
- Where each kind of error ends:
  - an unexpected character: the end of that character;
  - an unterminated string: the end of its first line;
  - a parse error: the end of the token it failed at;
  - an `unfinished statement`: the end of the statement's last token;
  - a type error: the node's `end_line` and `end_col`.

- [ ] **Step 1: Write the failing tests:**
  - `errors.new("m", 2, 3)` has end 2:4.
  - In recover mode, `let a = 1 @ 2` gives a diagnostic ending at 1:12.
  - `parse_all("let b = )")` gives a diagnostic from 1:9 to 1:10.
  - `parse_all("let x =\nlet y = 2\n")` gives a diagnostic from 1:7 to 1:8.
  - The type error for `let n : number = "s"` ends at 1:21.
  - For #43:
    - In the default mode, a multi-line string token `"a\nb"` has `line` 1.
    - `x = "abc\ndef` (unterminated) gives an error at 1:5.
- [ ] **Step 2: Run.** Expected: the end assertions fail. The two #43 tests pass, because they pin behaviour already changed in sub-project 1. That is the purpose of #43.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: `0 failures`.
- [ ] **Step 5: Commit.** `feat(errors): diagnostics carry an end position`

### Task 4: Name tokens on nodes

**Files:**
- Modify: `omelette/parser.lua`
- Test: `spec/name_tokens_spec.lua`

**Interfaces:**
- Produces: references to the lexer tokens of names the parser stores only as strings today. Tokens have `type`, not `kind`, so the range walk skips them.
  - A `let` with a name: `name_tok`. With parameters: `param_toks`, a list with one token per parameter, in order.
  - A `lambda`: `param_toks`.
  - A `type_decl`: `name_tok`. Each variant gets `name_tok`.
  - Each field of `table`, `construct`, `record_update`, `record_pat` and `ctor_pat`: `key_tok`.
  - A `field` node: `name_tok`.
  - A `generator`: `name_tok`, and `value_name_tok` when it has a second name.
- Generated Lua doesn't change.

- [ ] **Step 1: Write the failing tests:** for each node kind above, a one-line source whose name token has the expected `value`, `line` and `col`. For example:
  - `let f (x : number) y = x`: `name_tok` at 1:5, and `param_toks` at 1:8 and 1:20.
  - `type Shape = | Circle { r } | Dot`: variant name tokens at 1:16 and 1:31.
- [ ] **Step 2: Run.** Expected: they fail.
- [ ] **Step 3: Implement**, keeping the token that `expect` and `next` already return at each site.
- [ ] **Step 4: Run.** Expected: `0 failures`. Generated Lua for `std/*.egg` and `spec/fixtures/*.egg` is identical to `canon`'s.
- [ ] **Step 5: Commit.** `feat(parser): keep the tokens of declared names`

### Task 5: Positions and semantic tokens

**Files:**
- Create: `omelette/lsp/position.lua`, `omelette/lsp/tokens.lua`
- Test: `spec/lsp_position_spec.lua`, `spec/lsp_tokens_spec.lua`

**Interfaces:**
- Consumes: `parser.parse_all` (sub-project 1), and the name tokens from Task 4.
- Produces: `position.new(source, encoding) -> pos`, where `encoding` is `"utf-8"` or `"utf-16"`.
  - `pos:to_lsp(line, col) -> { line = line - 1, character = c }`. Here `c` counts the line's bytes before `col` in UTF-8, or its UTF-16 code units in UTF-16; a 4-byte UTF-8 sequence is 2 code units.
  - `pos:length(line, col, end_col) -> n`, the length of a span on one line, in the same unit.
- Produces: `tokens.LEGEND = { tokenTypes = {…}, tokenModifiers = { "declaration" } }`, in the order given under Global Constraints.
- Produces: `tokens.encode(parsed, pos) -> integer array`, the LSP relative encoding (delta line, delta start, length, type index, modifier bits). `parsed` is the result of `parse_all`.
- Classification:
  - First, from the lexer: keyword, string, number and operator tokens; comments; every `ident` as `variable`.
  - Then a walk of the tree changes the classification of ident tokens, matched by start position:
    - `type_name` nodes and the `type_decl` `name_tok` become `type`.
    - The start token of `construct` and `ctor_pat` nodes, and each variant's `name_tok`, become `enumMember`.
    - A `let`'s `name_tok` becomes `function` if it has `param_toks`, otherwise `variable`.
    - `param_toks` become `parameter`.
    - `key_tok`s and a `field` node's `name_tok` become `property`.
    - `var` patterns and generator name tokens become `variable`.
  - The `declaration` modifier goes on: `let` names, parameters, `type_decl` and variant names, `var` patterns, and generator names.
  - `punct` tokens and `eof` get no token.
  - A token that spans lines is split into one token per line.

- [ ] **Step 1: Write the failing tests:**
  - **Positions:**
    - In `let s = "é" + x`, `x` is character 15 in UTF-8 and 14 in UTF-16.
    - A line containing U+1F600 counts 2 UTF-16 units for it.
  - **Tokens:** each check decodes the integer array back to absolute `{ line, char, len, type, mods }` rows.
    - For `let f x = x + 1`:
      - `let` keyword at 0:0, length 3;
      - `f` function+declaration at 0:4;
      - the first `x` parameter+declaration at 0:6;
      - `=` operator at 0:8;
      - the second `x` variable at 0:10;
      - `+` operator at 0:12;
      - `1` number at 0:14.
    - `type T = | A | B` followed by `let v = A`: `T` is type+declaration, both `A`s are enumMember, and `v` is variable+declaration.
    - `-- c` on line 1 is a comment of length 4.
    - A literal two-line string `"ab\ncd"` gives two string tokens, of length 3 and 3.
    - `let b = )` followed by `let ok = 1`: the tokens on line 1 come from the lexer only, and `ok` is variable+declaration.
- [ ] **Step 2: Run.** Expected: they fail.
- [ ] **Step 3: Implement.** Collect the rows, sort them by position, then encode.
- [ ] **Step 4: Run.** Expected: `0 failures`.
- [ ] **Step 5: Commit.** `feat(lsp): positions and semantic tokens`

### Task 6: Server and `omelette lsp`

**Files:**
- Create: `omelette/lsp/server.lua`
- Modify: `omelette/cli.lua` (`lsp` command, `USAGE`)
- Test: `spec/lsp_server_spec.lua`, `spec/lsp_e2e_spec.lua`

**Interfaces:**
- Consumes: Tasks 1, 2, 3 and 5, and `typecheck.check`.
- Produces: `server.new(send) -> s`, where `send(message)` is called for each outgoing message.
  - `s:handle(message) -> nil | exit_code`. It returns a number only for `exit`: 0 after `shutdown`, otherwise 1.
- Produces: `server.run(input, output) -> exit_code`, which loops `rpc.read` and `s:handle`. At `eof` it returns 1.
- Produces: `omelette lsp`, which calls `os.exit(server.run(io.stdin, io.stdout))`. `USAGE` lists `lsp`.
- `initialize` result:
  - `positionEncoding` is `"utf-8"` if the client lists it in `capabilities.general.positionEncodings`, otherwise `"utf-16"`;
  - `textDocumentSync = { openClose = true, change = 1 }`;
  - `semanticTokensProvider = { legend = tokens.LEGEND, full = true }`;
  - `serverInfo = { name = "omelette", version = <init.lua version> }`.
- Documents are stored by URI, with their text.
  - `didOpen` and `didChange` both analyse the document. `didChange` uses the last entry of `contentChanges`.
  - Analysis runs `parse_all` and `typecheck.check` inside `pcall`, and then sends `publishDiagnostics`.
  - Each diagnostic has `severity = 1` and `source = "omelette"`, and its range comes from the start and end through `pos:to_lsp`.
  - `didClose` sends an empty list.
- If analysis throws (for example on #44's deep nesting), the server:
  - logs the error through `window/logMessage` (type 1);
  - publishes one diagnostic at 0:0–0:1: `omelette could not check this file: <error>`;
  - keeps going. Semantic tokens for that document then come from the lexer only.
- `semanticTokens/full` returns `{ data = json.array(...) }`. For an unknown URI it returns `{ data = [] }`.
- Errors:
  - An unknown request gets error `-32601`. An unknown notification is ignored.
  - An error inside a handler gets `-32603` and a log message.
  - A framing parse error is logged, and the loop continues.

- [ ] **Step 1: Write the failing tests.**
  - **`lsp_server_spec`**, with `send` collecting into a list:
    - `initialize` with and without `utf-8` offered.
    - Opening `let b = )` publishes one diagnostic, with range 0:8–0:9.
    - A change to `let b = 1` publishes an empty list, encoded as `[]`.
    - Semantic tokens for the open document.
    - Semantic tokens for an unknown URI give `{"data":[]}`.
    - An empty document and a document of only comments give `"diagnostics":[]`.
    - `string.rep("(", 200000)` gives the "could not check" diagnostic and a log message, and a later request still answers.
    - An unknown request gives `-32601`.
    - `shutdown` then `exit` returns 0, and `exit` alone returns 1.
  - **`lsp_e2e_spec`:** run `<arg[-1]> bin/omelette lsp > out; echo $? > code` with `io.popen(cmd, "w")`.
    - It writes framed `initialize`, `initialized`, `shutdown` and `exit` messages.
    - The output file holds two responses with ids 1 and 2.
    - The code file holds 0.
    - A second run that closes stdin without `exit` gives 1.
- [ ] **Step 2: Run.** Expected: they fail.
- [ ] **Step 3: Implement** `server.lua` and the CLI command.
- [ ] **Step 4: Run.** Expected: `0 failures`, under `luajit` and under `lua`.
- [ ] **Step 5: Try it.** Start Neovim with a throwaway config that calls `vim.lsp.start({ cmd = { "luajit", "<repo>/bin/omelette", "lsp" } })`. Open a `.egg` file and check that highlighting and errors appear.
- [ ] **Step 6: Commit.** `feat(lsp): omelette lsp — diagnostics and semantic tokens`

### Task 7: Packaging and the 0.2.0 release

**Files:**
- Modify: `rockspecs/omelette.rockspec.template` (`install_command`), `build/amalgamate.lua` (`MODULES`), `omelette/init.lua` (version), `CHANGELOG.md`, `README.md`, `docs/guide.md` (a short "Editor support" section)
- Test: `spec/amalgamate_spec.lua`

**Interfaces:**
- `install_command` also runs `mkdir -p $(LUADIR)/omelette/lsp` and `cp omelette/lsp/*.lua $(LUADIR)/omelette/lsp/`.
- `MODULES` adds `json`, `lsp.rpc`, `lsp.position`, `lsp.tokens` and `lsp.server`. The file for an entry is the name with each `.` replaced by `/`, and the module is `omelette.<name>`.
- The version is `0.2.0`.
- CHANGELOG `## [0.2.0]` lists:
  - `omelette lsp`;
  - `omelette check` reports every syntax error;
  - and for #43: a multi-line string's position is now its first line, and an unterminated string's error now points at the line where the string starts.

- [ ] **Step 1: Write the failing test.** The amalgamated script contains `package.preload["omelette.lsp.server"]`, and `json` loads from it.
- [ ] **Step 2: Run.** Expected: it fails.
- [ ] **Step 3: Implement** all the file changes above.
- [ ] **Step 4: Run.** Expected: `0 failures`.
- [ ] **Step 5: Check the packaged forms.**
  - Run `lua build/amalgamate.lua > dist/omelette`, then pipe an `initialize`/`shutdown`/`exit` exchange into `lua dist/omelette lsp`. Expected: two responses, exit code 0.
  - Run `luarocks make` on a rockspec generated from the template into a local tree (`--tree` in the scratchpad), then run the installed `omelette lsp` the same way. Expected: the same result.
- [ ] **Step 6: Commit.** `release: 0.2.0 — omelette lsp`

Open the PR after this task. Merging it creates the `v0.2.0` tag and runs the release.

### Task 8: The omelette.nvim plugin

Repository: `/Users/dennyabraham/projects/personal/omelette.nvim`, branch `canon`, empty. Work on a branch there and open a PR there.

**Files:**
- Create: `ftdetect/omelette.lua`, `ftplugin/omelette.lua`, `lsp/omelette.lua`, `plugin/omelette.lua`, `README.md`, `LICENSE` (MIT, matching `omelette-lang`), `tests/run.lua`, `.github/workflows/ci.yml`

**Interfaces:**
- The four plugin files have the contents given in the spec's "Neovim plugin" section.
- `ftplugin` sets `vim.bo.commentstring = "-- %s"`, `shiftwidth = 2`, `expandtab`, `autoindent`, and `vim.b.undo_ftplugin`.
- `tests/run.lua` runs with `nvim --clean --headless -l tests/run.lua` from the repository root. It adds the repository to `runtimepath`, runs `filetype plugin on`, prints `ok` or `FAIL <name>` for each test, and exits non-zero if any test fails.

- [ ] **Step 1: Write the failing tests** in `tests/run.lua`:
  - Editing `x.egg` sets `filetype` to `omelette`, `commentstring` to `-- %s` and `shiftwidth` to 2.
  - `vim.lsp.config.omelette.cmd` is `{ "omelette", "lsp" }`.
  - If `omelette` is executable and `omelette lsp` starts: a client named `omelette` attaches within 5 seconds, and semantic tokens for `let f x = x` are non-empty. Otherwise the test prints `skip`.
- [ ] **Step 2: Run.** Expected: `FAIL` lines, because there are no plugin files yet.
- [ ] **Step 3: Implement** the four plugin files.
- [ ] **Step 4: Run.** Expected: all `ok`, with the attach test run against a local install of the branch from Task 7.
- [ ] **Step 5: Write CI and the README.**
  - CI: `rhysd/action-setup-vim@v1` with stable Neovim, `leafo/gh-actions-lua@v10` (Lua 5.4) and `leafo/gh-actions-luarocks@v4`, then `luarocks install omelette 0.2.0`, then `nvim --clean --headless -l tests/run.lua`.
  - README: the lazy.nvim line `{ "dennyabraham/omelette.nvim" }`, the requirements (Neovim 0.11+, omelette 0.2.0+ on `PATH`), and a link to the spec.
- [ ] **Step 6: Commit and open the PR.** `feat: file type, buffer options and LSP config for Omelette`. CI goes green once 0.2.0 is on LuaRocks, so merge it after the release.
