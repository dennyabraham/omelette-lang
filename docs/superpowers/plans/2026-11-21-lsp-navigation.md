# LSP Hover, Definition and Symbols Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `omelette lsp` answers hover, go-to-definition and document symbols, and semantic tokens classify each use of a name by its binding. Released in omelette 0.3.0.

**Architecture:** The type checker records, for every name it resolves, the declaration it resolves to, and the type of every expression. A new module turns that into a list of name occurrences that can be searched by position. Hover, definition and semantic tokens all read that list. Document symbols are read straight from the top-level statements.

**Tech Stack:** Lua 5.1 / LuaJIT / Lua 5.4, with no dependencies.

**Spec:** `docs/superpowers/specs/2026-11-20-lsp-navigation-design.md`

## Abstract

Five tasks, all in `omelette-lang`, on one branch and one PR. Task 5 bumps the version to 0.3.0, so merging the PR tags and publishes the release. `omelette.nvim` needs no change: Neovim turns hover, definition and symbols on when the server's capabilities list them.

Three decisions go beyond the spec:
- **Name occurrences instead of the node-at-position helper.** The spec's helper finds the innermost node at a position. All three features only need names. Declared names are tokens, not nodes (`name_tok`, `param_toks`), so a node search would not find them. Task 2 builds a list of every name occurrence, uses and declarations, each with its byte range and declaration.
- **Definition of a constructor goes to its variant.** The spec says a constructor binds to its `type` declaration. Go-to-definition on `Circle` jumps to `Circle` inside that declaration. Hover on it shows the whole declaration, as the spec says.
- **The checker walks comprehensions.** Today it returns `any` for them without looking inside, so their variables have no bindings. Task 1 walks them, with every generator variable typed `any`. This also means type errors inside comprehensions are reported for the first time, which the CHANGELOG notes.

## Contents

- [Global Constraints](#global-constraints)
- [Review Focus](#review-focus)
- [Task 1: Bindings and types in the checker](#task-1-bindings-and-types-in-the-checker)
- [Task 2: Name occurrences and semantic tokens by binding](#task-2-name-occurrences-and-semantic-tokens-by-binding)
- [Task 3: Hover and go-to-definition](#task-3-hover-and-go-to-definition)
- [Task 4: Document symbols](#task-4-document-symbols)
- [Task 5: Packaging, docs and the 0.3.0 release](#task-5-packaging-docs-and-the-030-release)

## Global Constraints

- No new rock dependency. Code runs on Lua 5.1, LuaJIT and Lua 5.4.
- Tests: `luajit spec/run.lua` and `lua spec/run.lua`. Success is a last line of `N tests, 0 failures`.
- `typecheck.check(program)` keeps returning the diagnostics list first. Existing callers do not change.
- Definitions are found within one file. Names from other modules and Lua globals have no binding and give no result.
- Compiler positions are 1-based byte columns. LSP positions are 0-based, in the negotiated encoding (`utf-8` or `utf-16`).
- "No result" is JSON `null` for hover and definition, and `[]` for document symbols.

## Review Focus

1. **A position on no name.** Hover and definition on whitespace, a keyword, a number, past the end of a line or past the end of the file give `null`, not an error. Tested in Task 3.
2. **A document whose analysis failed.** For a file the server could not check (200,000 nested `(`), hover and definition give `null` and symbols give `[]`. Tested in Tasks 3 and 4.
3. **UTF-16 request positions.** In `let s = "é" + x`, a hover request at UTF-16 character 14 finds `x`. Tested in Task 3.
4. **Destructuring `let`.** `let (a, b) = t` gives a Variable symbol for each of `a` and `b`, and a use of `a` jumps to it. Tested in Tasks 1 and 4.
5. **A name in a statement that failed to parse.** In `let b = )\nlet c = b`, the `b` use binds to nothing, so hover and definition give `null`, and the server does not crash. Tested in Task 3.

---

### Task 1: Bindings and types in the checker

**Files:**
- Modify: `omelette/typecheck.lua`
- Test: `spec/bindings_spec.lua` (new)

**Interfaces:**
- Produces: `typecheck.check(program)` returns `diags, binding_of, type_of`.
  - `binding_of[node] = decl` for each `ident` use, `construct` node, `ctor_pat` node and user-declared `type_name` node.
  - `decl = { name, kind, line, col, end_line, end_col, node, type }`. `kind` is one of `"function"`, `"variable"`, `"parameter"`, `"type"`, `"enumMember"`, the same names as the token legend. The position fields are the range of the declared name. `node` is the declaring node: the `let`, the lambda, the pattern `var`, the `generator` or the `type_decl`. A constructor's `node` is its `type_decl`. `type` is the checker's type for the name.
  - `type_of[node] = type` for every node `synth` visits.
- A `let` with parameters is `"function"`. Any other `let`, a pattern variable or a generator variable is `"variable"`. Let and lambda parameters are `"parameter"`.

- [ ] **Step 1: Write the failing tests** in `spec/bindings_spec.lua`. A helper `bind(src)` parses with `parser.parse`, runs `typecheck.check`, and returns `binding_of`. Another, `use_at(program, line, col)`, finds the `ident` node starting there.
  - `binds a parameter use to the parameter`: in `let f x = x`, the use at 1:11 has `kind "parameter"` and range `1:7–1:8`.
  - `binds a shadowing lambda parameter, not the outer name`: in `let x = 1\nlet g = fn x -> x`, the use at 2:17 binds to the decl at 2:12, `kind "parameter"`.
  - `binds a match arm's pattern variable`: in `let m v = match v with | { y } -> y`, the `y` after `->` binds to the pattern var, `kind "variable"`.
  - `binds comprehension variables`: in `let ys xs = [ x * 2 | x <- xs ]`, the `x` in `x * 2` binds to the generator's `name_tok`. In `let m t = { k => v | k, v <- t }`, `v` binds to `value_name_tok`.
  - `binds mutually recursive top-level functions`: in `let even n = if n == 0 then true else odd(n - 1)\nlet odd n = if n == 0 then false else even(n - 1)`, the `odd` on line 1 binds to line 2's `let`, `kind "function"`.
  - `binds a destructured name`: in `let (a, b) = (1, 2)\nlet c = a`, the `a` on line 2 binds to the `var` at 1:6.
  - `binds constructors and type names to their declaration`: in `type Shape = | Circle { r } | Dot\nlet area (s : Shape) = match s with | Circle { r } -> r | Dot -> 0\nlet d = Dot`, the `construct` `Dot` and the `ctor_pat` `Circle` have `kind "enumMember"` with `node` the `type_decl`. The `type_name` `Shape` has `kind "type"`.
  - `leaves a Lua global unbound`: in `let p = print(1)`, `print` has no entry.
  - `records the type of a use`: in `let n : number = 1\nlet m = n`, `type_of` of the `n` use is `{ kind = "number" }`.

- [ ] **Step 2: Run** `luajit spec/run.lua`. Expected: these tests fail, because `check` returns only the diagnostics.

- [ ] **Step 3: Implement.** Each scope gets a `decls` map beside `vars`, filled wherever `vars` is filled: top-level pass 1, `check_binding`, lambda parameters, match arms, destructuring. `collect_pattern_vars` collects the `var` nodes rather than only their names. `synth` records `type_of[node]` for every node. For an `ident` it records `binding_of` from a `decls` lookup. For `construct` it uses `ctor_owner`, which also keeps the variant's `name_tok` and its `type_decl`. `validate_pattern` binds `ctor_pat` nodes the same way. Annotations are walked for `type_name` nodes that name a declared type. Comprehensions and dict comprehensions get one new scope. Each qualifier is checked in order: a generator synthesizes its `source`, then binds its names as `any`; a guard synthesizes its `cond`. Then the yield, or the key and value, are synthesized. `range` synthesizes both ends.

- [ ] **Step 4: Run** `luajit spec/run.lua` and `lua spec/run.lua`. Expected: `N tests, 0 failures` under both.

- [ ] **Step 5: Commit** `feat(typecheck): record each name's binding and each expression's type`.

### Task 2: Name occurrences and semantic tokens by binding

**Files:**
- Create: `omelette/lsp/names.lua`
- Modify: `omelette/lsp/tokens.lua`, `omelette/lsp/server.lua` (`analyse` keeps the index)
- Test: `spec/lsp_names_spec.lua` (new), `spec/lsp_tokens_spec.lua`

**Interfaces:**
- Consumes: `binding_of`, from Task 1.
- Produces:
  - `names.index(binding_of)` returns a list of occurrences `{ line, col, end_col, decl, is_decl }`, sorted by position.
    - A use's range is its name: an `ident` node's range; for a `construct` or `ctor_pat`, its start plus `#tag`; for a `type_name`, its range.
    - Each distinct `decl` adds one occurrence with `is_decl = true`.
  - `names.at(index, line, col)` returns the occurrence with `col <= c < end_col` on that line, or `nil`.
  - `tokens.encode(parsed, pos, index)`: `index` is optional. A use with an occurrence takes `decl.kind` as its class, without the `declaration` modifier.
  - The server's `analyse` result gains `index`, which is `nil` when analysis failed.

- [ ] **Step 1: Write the failing tests.**
  - `spec/lsp_names_spec.lua`, `finds a use and its declaration by position`: in `let f x = x`, `names.at(idx, 1, 11)` is a use whose decl is at 1:7; `names.at(idx, 1, 7)` has `is_decl = true`; `names.at(idx, 1, 9)` (the `=`) is `nil`.
  - `spec/lsp_tokens_spec.lua`, `classifies uses by their binding`: in `let f x = x\nlet y = f(1)`, the `x` use at 0:10 is `parameter`, and the `f` at 1:8 is `function` without the declaration modifier. The existing `rows` helper gains the index.

- [ ] **Step 2: Run** `luajit spec/run.lua`. Expected: the new tests fail; `names` does not exist.

- [ ] **Step 3: Implement** `names.lua` and the `tokens.encode` change. Then change `analyse` to keep `check`'s second return and build the index.

- [ ] **Step 4: Run** both interpreters. Expected: `N tests, 0 failures`. The existing token tests still pass unchanged.

- [ ] **Step 5: Commit** `feat(lsp): semantic tokens classify a name's uses by its binding`.

### Task 3: Hover and go-to-definition

**Files:**
- Modify: `omelette/typecheck.lua` (`format_type`), `omelette/lsp/position.lua` (`from_lsp`), `omelette/lsp/server.lua`
- Test: `spec/bindings_spec.lua`, `spec/lsp_tokens_spec.lua` (positions), `spec/lsp_server_spec.lua`

**Interfaces:**
- Consumes: `names.at`, and the document's `index`, from Task 2.
- Produces:
  - `typecheck.format_type(t)` returns a string. Primitives print their kind (`number`, `string`, `boolean`, `nil`, `any`). A function prints `(p1, p2) -> ret` with the parameters always in parentheses: `() -> any`, `(number) -> number`, `((number) -> number) -> number`.
  - `position:from_lsp(line, character)` returns `line, col`, the inverse of `to_lsp` in either encoding.
  - Capabilities gain `hoverProvider = true` and `definitionProvider = true`.
  - `textDocument/hover` returns `{ contents = { kind = "markdown", value = <a fenced omelette block> }, range = <the occurrence> }`, or `null`. The text in the block is:
    - a name whose type is not `any`: `name : <format_type>`;
    - a name of type `any`: the declaration's source line, trimmed;
    - a constructor or a type name: the `type_decl`'s source, from its start to its end.
  - `textDocument/definition` returns `{ uri, range = <decl range> }` for the same document, or `null`.

- [ ] **Step 1: Write the failing tests.**
  - `format_type` for each primitive, plus the three function examples above (in `spec/bindings_spec.lua`, built from literal type tables).
  - `from_lsp`: in `let s = "é" + x`, UTF-16 `(0, 14)` gives `1, 16`, and UTF-8 `(0, 15)` gives `1, 16`.
  - Server tests, which open the fixture `let n : number = 1\nlet f x = x + n\ntype T = | A | B\nlet v = A`:
    - `hovers a typed name`: at the `n` on line 1 (0-based), the value contains `n : number`.
    - `hovers a name of type any with its declaration line`: at the `x` use on line 1, the value contains `let f x = x + n`.
    - `hovers a constructor with its type declaration`: at `A` on line 3, the value contains `type T = | A | B`.
    - `jumps to a definition`: at the `n` use, the result's range starts at `{ line = 0, character = 4 }`.
    - `gives null on no name`: hover and definition at the `=` on line 0, at character 200 on line 0, and at line 50 all give `null`.
    - `gives null for a name from a failed statement`: open `let b = )\nlet c = b`; hover at the second `b` gives `null`.
    - `gives null for a file it could not check`: open 200,000 `(`; hover at `(0, 0)` gives `null`.
    - `hovers under UTF-16`: start without UTF-8, open `let s = "é" + x`, and hover at `(0, 14)`. The result's range starts at character 14.

- [ ] **Step 2: Run** `luajit spec/run.lua`. Expected: the new tests fail.

- [ ] **Step 3: Implement** `format_type`, `from_lsp`, the two capabilities and the two request handlers. A request for an unknown URI, or for a document with no `index`, returns `null`.

- [ ] **Step 4: Run** both interpreters. Expected: `N tests, 0 failures`.

- [ ] **Step 5: Commit** `feat(lsp): hover and go to definition`.

### Task 4: Document symbols

**Files:**
- Create: `omelette/lsp/symbols.lua`
- Modify: `omelette/lsp/server.lua`
- Test: `spec/lsp_server_spec.lua`

**Interfaces:**
- Produces:
  - `symbols.document(program, pos)` returns an array of `DocumentSymbol`s: `{ name, kind, range, selectionRange, children }`.
  - `kind` values:
    - a top-level `let` with parameters is `12` (Function); any other `let` is `13` (Variable);
    - a destructuring `let` gives one `13` per bound name, each with that `var` as its selection range;
    - a `type_decl` is `10` (Enum), with a `22` (EnumMember) child for each variant.
  - `range` is the whole node, and `selectionRange` is the name token. `children` is an empty array where there are none.
  - Capability `documentSymbolProvider = true`, and the request `textDocument/documentSymbol`.

- [ ] **Step 1: Write the failing tests.**
  - `lists the file's symbols`: the fixture `let f x = x\nlet v = 1\nlet (a, b) = (1, 2)\ntype S = | P | Q` gives names `f, v, a, b, S` with kinds `12, 13, 13, 13, 10`. `S` has children `P, Q` of kind `22`. `f`'s `selectionRange` is `0:4–0:5` and its `range` ends at `0:11`.
  - `gives no symbols for a file it could not check`: for 200,000 `(`, the raw JSON contains `"result":[]`.

- [ ] **Step 2: Run** `luajit spec/run.lua`. Expected: the new tests fail.

- [ ] **Step 3: Implement** `symbols.lua` and the handler. A document whose analysis failed has an empty program, so it already gives `[]`.

- [ ] **Step 4: Run** both interpreters. Expected: `N tests, 0 failures`.

- [ ] **Step 5: Commit** `feat(lsp): document symbols`.

### Task 5: Packaging, docs and the 0.3.0 release

**Files:**
- Modify: `build/amalgamate.lua`, `spec/amalgamate_spec.lua`, `omelette/init.lua`, `CHANGELOG.md`, `docs/guide.md`, `docs/ROADMAP.md`
- The rockspec already installs `omelette/lsp/*.lua`.

- [ ] **Step 1: Write the failing test.** `spec/amalgamate_spec.lua` gains `package.preload["omelette.lsp.names"]` and `package.preload["omelette.lsp.symbols"]` in the existing bundle test.

- [ ] **Step 2: Run** `luajit spec/run.lua`. Expected: that test fails.

- [ ] **Step 3: Add** `lsp.names` and `lsp.symbols` to the amalgamator's `MODULES`, after `lsp.tokens`.

- [ ] **Step 4: Update the release files.**
  - `omelette/init.lua`: version `"0.3.0"`.
  - `CHANGELOG.md`: the `[Unreleased]` heading becomes `[0.3.0]`, keeping its CRLF entry. Add:
    - hover, go to definition and document symbols in `omelette lsp`;
    - semantic tokens classify uses by their binding;
    - `omelette check` now reports type errors inside comprehensions.
  - `docs/guide.md`, Editor support: one sentence naming hover, go to definition and the symbol outline. Definitions are found within the same file.
  - `docs/ROADMAP.md`: LSP navigation moves to Shipped, under Editor support (0.3.0).

- [ ] **Step 5: Verify the packaged server.**
  - Run `lua build/amalgamate.lua`.
  - Send `dist/omelette lsp` an `initialize` request. Expected: the result lists `hoverProvider`, `definitionProvider` and `documentSymbolProvider`, with version `0.3.0`.
  - In Neovim, with the plugin and `bin` on `PATH`, run `vim.lsp.buf.hover` on a name in a fixture file. Expected: the hover window shows `name : type`. Run `vim.lsp.buf.definition` on a use. Expected: the cursor moves to its declaration.

- [ ] **Step 6: Run** both interpreters. Expected: `N tests, 0 failures`. Commit `release: 0.3.0 — hover, definition and symbols`.
