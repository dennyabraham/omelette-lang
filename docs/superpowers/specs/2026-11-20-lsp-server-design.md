# Omelette — LSP Server and Neovim Plugin Design

**Date:** 2026-11-20
**Status:** Approved design, pre-implementation
**Part of:** editor support, sub-project 2 of 3. Depends on
[parsing for editors](2026-11-20-editor-parsing-design.md). Followed by
[hover, definition and symbols](2026-11-20-lsp-navigation-design.md).

## Abstract

`omelette lsp` is a language server in the omelette rock. It gives diagnostics as the
user types and highlights `.egg` files with semantic tokens. There is no Vim syntax
file: all highlighting comes from the server. The Neovim plugin, in the separate
`omelette.nvim` repository, sets the file type, the buffer options, and starts the
server. The rock stays free of dependencies; it gets its own JSON code.

## Contents

- [Decisions](#decisions)
- [Server](#server)
  - [Files](#files)
  - [Methods](#methods)
  - [Positions](#positions)
  - [Semantic tokens](#semantic-tokens)
  - [Errors](#errors)
- [Neovim plugin](#neovim-plugin)
- [Release](#release)
- [Tests](#tests)

## Decisions

| Question | Decision | Reason |
|---|---|---|
| Highlighting | Semantic tokens from the server only | One grammar (the compiler's); no regex or tree-sitter grammar to keep in step. Cost: no colour while the server is not running. |
| Packaging | `omelette lsp` subcommand, same rock | Server and compiler always the same version; no dependency added. Cost: about 150 lines of JSON code to test. |
| Plugin location | Separate repository, `dennyabraham/omelette.nvim` | Installable by name with lazy.nvim; compiler repository root stays free of editor files. |

## Server

The server reads messages from stdin and writes to stdout. It is single-threaded and
handles one message at a time, in order.

### Files

- `omelette/json.lua` — JSON encode and decode, including `\uXXXX` escapes and
  surrogate pairs.
- `omelette/lsp/rpc.lua` — reads and writes the `Content-Length` header framing.
- `omelette/lsp/server.lua` — message dispatch and the store of open documents.
- `omelette/lsp/tokens.lua` — builds the semantic token data.
- `omelette/cli.lua` — adds the `lsp` command.

### Methods

- Lifecycle: `initialize`, `initialized`, `shutdown`, `exit`.
- Document sync: `textDocument/didOpen`, `didChange` and `didClose`, with full-text
  sync.
- After each open or change, the server runs `parse_all` and the type checker on the
  document and sends `textDocument/publishDiagnostics`. On close, it sends an empty
  list.
- `textDocument/semanticTokens/full`.

### Positions

- The server uses UTF-8 columns when the client lists `utf-8` in
  `general.positionEncodings` (Neovim does). Otherwise it uses UTF-16 and converts
  each line.
- Compiler positions are 1-based; LSP positions are 0-based. The server converts.
- `errors.new` takes an optional end position. A parse error spans the token where it
  happened. A type error spans the node it is about.

### Semantic tokens

All types are standard LSP token types.

| Source | Token type |
|---|---|
| Keyword token | `keyword` |
| String token | `string` |
| Number token | `number` |
| Comment | `comment` |
| Operator token | `operator` |
| Type name in an annotation or a `type` declaration | `type` |
| Constructor, in an expression or a pattern | `enumMember` |
| Name bound by a `let` that takes parameters | `function` |
| Parameter of a `let` or a lambda | `parameter` |
| Record field name | `property` |
| Any other identifier | `variable` |

- The `declaration` modifier marks the place where a name is bound.
- In this sub-project, `function` and `parameter` apply where the name is declared.
  Uses of the name get the kind of their binding in sub-project 3.
- Identifiers inside a statement that failed to parse get only the lexer's
  classification (`variable`).
- A token that spans lines is split into one token per line, because clients need
  not support tokens that cross lines.

### Errors

- Each message is handled inside its own `pcall`. An internal error is reported to the
  client with `window/logMessage`; a request that fails gets an error response. The
  server keeps running.
- A message whose JSON does not parse is logged and skipped.
- `exit` without a `shutdown` before it exits with code 1, as the LSP specification
  requires.

## Neovim plugin

Repository: `dennyabraham/omelette.nvim`. Requires Neovim 0.11 or later
(`vim.lsp.config`) and `omelette` 0.2.0 or later on `PATH`.

- `ftdetect/omelette.lua` — `*.egg` files get file type `omelette`.
- `ftplugin/omelette.lua` — `commentstring` `-- %s`, `shiftwidth=2`, `expandtab`,
  `autoindent`. Two spaces matches the code in `std/`.
- `lsp/omelette.lua` — `cmd = { "omelette", "lsp" }`, `filetypes = { "omelette" }`,
  `root_markers = { ".git" }`.
- `plugin/omelette.lua` — calls `vim.lsp.enable("omelette")`.
- README: installation (`{ "dennyabraham/omelette.nvim" }` in lazy.nvim), the
  `omelette` version it needs, and a link to this spec.
- Unverified: that Neovim links every standard `@lsp.type.*` group to a default
  highlight group. If a token type shows no colour in testing, the plugin adds the
  missing link.

## Release

- The server ships in omelette 0.2.0. The version changes in its minor part because
  the release adds a command.
- `omelette.nvim` gets its first tag after 0.2.0 is on LuaRocks.

## Tests

In `omelette-lang`:

- JSON: round trips of every value type; escapes; `\uXXXX` with surrogate pairs;
  invalid input gives an error, not a crash.
- Framing: one message; two messages in one read; one message split across reads.
- Semantic tokens: encoded data for a fixture file, compared with deltas worked out by
  hand; a multi-line string; a file with a statement that does not parse.
- Server: driven in-process by a scripted sequence of messages: initialize, open,
  change, diagnostics, semantic tokens, shutdown, exit.
- End to end: `omelette lsp` run as a subprocess with `arg[-1]` as the interpreter,
  through initialize and shutdown.

In `omelette.nvim`, headless `nvim`:

- Opening `x.egg` sets file type `omelette` and the buffer options.
- With `omelette` installed, a client attaches and semantic tokens are returned. CI
  installs `omelette` from LuaRocks, so this test runs in CI from 0.2.0 on.
