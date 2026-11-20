# Parsing for Editors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A lexer and parser that keep going after errors and give every token and node a range, for the LSP server in sub-project 2.

**Architecture:** The lexer gains token ends, a comments list and a recovering mode. The parser gains a range on every node and a `parse_all` entry point that catches errors per top-level statement. `compiler.check` moves to `parse_all`. `parse`, `compile`, `build`, `run` and the REPL keep their behaviour.

**Tech Stack:** Lua 5.1 / LuaJIT / Lua 5.4; the repository's own test harness (`spec/support/harness.lua`).

**Spec:** `docs/superpowers/specs/2026-11-20-editor-parsing-design.md`

## Abstract

Four tasks:

1. The lexer gets token ends, comments and recovery.
2. The parser gets node ranges.
3. The parser gets statement-level recovery.
4. `omelette check` lists every syntax error.

Each task is one commit with its own tests. The suite has 376 tests and must stay green throughout. Nineteen existing assertions compare whole tokens or nodes, so they would break once those gain new fields. A harness helper strips the new fields from the actual values in those assertions. There is no version bump and no CHANGELOG entry in this plan: both come with the 0.2.0 release in sub-project 2.

## Contents

- [Global Constraints](#global-constraints)
- [Review Focus](#review-focus)
- [Task 1: Lexer ends, comments, recovery](#task-1-lexer-ends-comments-recovery)
- [Task 2: Node ranges](#task-2-node-ranges)
- [Task 3: Statement recovery](#task-3-statement-recovery)
- [Task 4: Check command](#task-4-check-command)

## Global Constraints

- Code runs on Lua 5.1, LuaJIT and Lua 5.4. CI runs all three.
- Run the tests with `luajit spec/run.lua`, from the repository root. Success is a last line of `N tests, 0 failures`.
- Any test that spawns a process uses `arg[-1]` as the interpreter, never a hard-coded `luajit`.
- Columns are 1-based byte columns. `end_col` is the column just after the last character.
- `parser.parse`, `lexer.tokenize` without options, `compiler.compile` and generated Lua do not change behaviour.
- Comments in code follow the existing density: short, and they explain why, not what.

## Review Focus

1. **A broken statement takes in the statements after it.** The parser doesn't use layout, so `let x =` followed by `let y = 2` and `let z = 3` reads `y` and `z` as the body of `x`, and fails at the end of the file. Recovery must restart from the start of `x` and keep both `y` and `z`. Tested in Task 3.
2. **An indented `let` is not a sync point.** A `let` inside a function body, in column 3, must not restart parsing in the middle of the broken function. Tested in Task 3.
3. **The file ends in the middle of a statement.** `let x =` at the end of the file gives one diagnostic, and the parser stops. Tested in Task 3.
4. **Multi-byte UTF-8.** A string containing `é` gets an `end_col` in bytes, not characters. Tested in Task 1.
5. **An unterminated string on the last line, with no trailing newline,** ends at the end of the file, without an error from the lexer itself. Tested in Task 1.

---

### Task 1: Lexer ends, comments, recovery

**Files:**
- Modify: `omelette/lexer.lua`
- Modify: `spec/support/harness.lua`
- Modify: the nine spec files with whole-token or whole-node assertions: `lexer_spec`, `comprehension_lexer_spec`, `dict_comprehension_spec`, `parser_expr_spec`, `pattern_parse_spec`, `sumtype_parse_spec`, `annotation_spec`, `range_spec`, `length_spec`
- Test: `spec/lexer_editor_spec.lua` (new)

**Interfaces:**
- Produces: every token has `end_line` and `end_col`.
- Produces: `lexer.tokenize(source, { recover = true })` returns a single table `{ tokens, comments, diagnostics }`. `comments` holds `{ text, line, col, end_line, end_col }`, where `text` includes the `--`. `diagnostics` holds `errors.new` values. The function never returns nil.
- Produces: `h.without_ends(v)`, a deep copy of `v` with `end_line`, `end_col`, `start_line` and `start_col` removed at every level.
- Unchanged: `lexer.tokenize(source)` returns `toks, nil` or `nil, err`.

- [ ] **Step 1: Write the failing tests** in `spec/lexer_editor_spec.lua`:
  - `x + 12`: ends at 1:2, 1:4 and 1:7.
  - The string `"a\nb"`, written with an escaped `\n`, ends at 1:7, after the closing quote.
  - A literal string running from line 1 to line 2 has `end_line` 2.
  - `"é"` has `end_col` 5 (the `é` is two bytes).
  - `x -- note` in recover mode gives one comment, `{ text = "-- note", line = 1, col = 3, end_line = 1, end_col = 10 }`.
  - `let a = 1 @ 2` in recover mode gives one diagnostic, `unexpected character '@'` at 1:11. The tokens skip the `@`.
  - `let s = "abc` followed by a newline and `let t = 1` gives one `unterminated string` diagnostic at 1:9. The string token ends at the end of line 1, and line 2 lexes as `let t = 1`.
  - `let s = "abc` with no trailing newline gives a string token ending at the end of the file, and one diagnostic.
  - Without options, the result for `@` is still `nil` and an error.
- [ ] **Step 2: Run it.** `luajit spec/run.lua`. Expected: the new tests fail, and the existing 376 pass.
- [ ] **Step 3: Implement** the token ends, the comments list and the recover option in `lexer.lua`. When recovery ends an unterminated string at the end of its line, the newline is not part of the token.
- [ ] **Step 4: Run it.** Expected: the new tests pass, and the 19 old whole-value assertions fail.
- [ ] **Step 5: Add `h.without_ends`** to the harness. Wrap the actual value, never the expected value, in each failing assertion.
- [ ] **Step 6: Run it.** Expected: `0 failures`.
- [ ] **Step 7: Commit.** `feat(lexer): token end positions, comments list, recovering mode`

### Task 2: Node ranges

**Files:**
- Modify: `omelette/parser.lua`
- Test: `spec/node_range_spec.lua` (new)

**Interfaces:**
- Consumes: token `end_line` and `end_col` (Task 1).
- Produces: every node, including `generator` and `guard`, has `start_line`, `start_col`, `end_line` and `end_col`. Existing `line` and `col` don't change.
- Produces: `Parser:finish(node, start_tok)` sets the range from `start_tok` to the last consumed token (`self.toks[self.pos - 1]`) and returns `node`. It is called wherever a node is built.
  - For left-nested nodes (`binop`, `pipe`, `call`, `field`, `index`), the start comes from the left child's range.
  - `program` and `block` take their range from their first and last children. An empty program has the range 1:1 to 1:1.

- [ ] **Step 1: Write the failing tests** in `spec/node_range_spec.lua`:
  - `1 + 2 * 3`: the root `binop` has the range 1:1 to 1:10, and its `line`/`col` is still 1:3.
  - `f(x)[1].y`: the outer `field` node has the range 1:1 to 1:10.
  - A walk over every `.egg` file in `std/` and `spec/fixtures/`, and every `egg` block in `docs/guide.md` that `parser.parse` accepts. Use `dt.extract` from `spec/support/doctest.lua` to get the blocks. For every table with a `kind` field, it asserts:
    - all four range fields are numbers;
    - the end is not before the start;
    - the range lies inside the nearest enclosing node's range.
  - Failure messages name the file, the node's `kind` and its range.
- [ ] **Step 2: Run it.** Expected: the new tests fail, because there are no range fields yet.
- [ ] **Step 3: Implement `Parser:finish`** and call it at every place a node is built, including patterns, type expressions and qualifiers.
- [ ] **Step 4: Run it.** Expected: `0 failures`. If the walk names a node kind, a `finish` call is missing at that kind's construction site.
- [ ] **Step 5: Commit.** `feat(parser): source range on every syntax tree node`

### Task 3: Statement recovery

**Files:**
- Modify: `omelette/parser.lua` (`parse_program`, new `parse_all`)
- Test: `spec/parse_all_spec.lua` (new)

**Interfaces:**
- Consumes: `lexer.tokenize(source, { recover = true })` (Task 1).
- Produces: `parser.parse_all(source)` returns `{ program, tokens, comments, diagnostics }`. `diagnostics` holds the lexer's and the parser's diagnostics, sorted by line, then column. `program.stmts` holds the statements that parsed. The function never returns nil.
- Recovery rule: when a top-level statement fails, record `self.err` and clear it. Then set `self.pos` to the first `let`, `pub` or `type` keyword token in column 1 that comes after the statement's first token, or to `eof`. This means going back to the statement's start, not continuing from the error (see Review Focus 1).
- `parser.parse` keeps stopping at the first error. Recovery runs only when `parse_program` is called from `parse_all`.

- [ ] **Step 1: Write the failing tests** in `spec/parse_all_spec.lua`:
  - Each test below names its statements by line. A valid statement is `let ok = 1`. A broken statement is `let b = )`, which fails at once rather than taking in the lines after it.
  - Valid, broken, valid, broken, valid: two diagnostics, and three statements in `program.stmts`.
  - `let x =` on line 1, `let y = 2` on line 2 and `let z = 3` on line 3: one diagnostic, and `program.stmts` holds `y` and `z`.
  - A function whose body contains an indented broken `let`, followed by `let g = 1` in column 1: one diagnostic, and `g` is parsed.
  - `let a = 1` followed by `let x =` at the end of the file: one diagnostic, and `a` is parsed.
  - A file of only `) ) )`: the call returns, with at least one diagnostic.
  - A lexer error and a parser error in different statements are both returned, in source order.
  - `parser.parse` on the first file still returns `nil` and the first error.
- [ ] **Step 2: Run it.** Expected: the new tests fail with `parse_all` undefined.
- [ ] **Step 3: Implement `parse_all`** and the recovery in `parse_program`, using a flag on the parser so that `parse` doesn't recover. Real Lua errors, those other than `__parse__`, are still re-raised.
- [ ] **Step 4: Run it.** Expected: `0 failures`.
- [ ] **Step 5: Commit.** `feat(parser): parse_all recovers at the next top-level statement`

### Task 4: Check command

**Files:**
- Modify: `omelette/compiler.lua` (`M.check`)
- Test: `spec/cli_spec.lua`, `spec/compiler_spec.lua`

**Interfaces:**
- Consumes: `parser.parse_all` (Task 3).
- Produces: `compiler.check(source)` returns the parse diagnostics, then the type diagnostics, with `nil` as its second value. The type checker runs on the `program` from `parse_all`. The `cmd_check` output format doesn't change.

- [ ] **Step 1: Write the failing tests.**
  - `compiler_spec`: `compiler.check` on a source with two broken statements (`let b = )`) and a valid one between them returns two diagnostics, the first being on the first broken line.
  - `cli_spec`: `omelette check` on such a file prints two `error:` lines and exits 1. Follow the existing `cli_spec` pattern for running the command.
  - `compiler_spec`: a file with one syntax error and one type error (`let n : number = "s"`, reported as `'n' is declared number but assigned string`) in a different statement returns both, with the syntax error first.
- [ ] **Step 2: Run it.** Expected: the new tests fail, because only one diagnostic comes back.
- [ ] **Step 3: Implement** the change to `M.check`.
- [ ] **Step 4: Run it.** Expected: `0 failures`. Also run `lua spec/run.lua` under Lua 5.4 if it is installed.
- [ ] **Step 5: Commit.** `feat(check): report every syntax error, not only the first`
