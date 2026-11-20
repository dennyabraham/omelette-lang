# Omelette — Parsing for Editors Design

**Date:** 2026-11-20
**Status:** Approved design, pre-implementation
**Part of:** editor support, sub-project 1 of 3. Sub-project 2 is
[the LSP server and Neovim plugin](2026-11-20-lsp-server-design.md); sub-project 3 is
[hover, definition and symbols](2026-11-20-lsp-navigation-design.md).

## Abstract

An editor needs a parse of a file that is broken while the user types. Today the lexer
and the parser stop at the first error, tokens record only where they start, the lexer
drops comments, and syntax tree nodes record only where they start. This sub-project
adds a recovering mode to the lexer and the parser, end positions on tokens and nodes,
and a list of comments. `build` and `run` keep their current behaviour. `omelette check`
reports every syntax error instead of only the first.

## Contents

- [Lexer](#lexer)
- [Parser recovery](#parser-recovery)
- [Node ranges](#node-ranges)
- [Check command](#check-command)
- [Unchanged behaviour](#unchanged-behaviour)
- [Tests](#tests)

## Lexer

- Every token gets `end_line` and `end_col`. `end_col` is the column just after the
  token's last character. A token that spans lines (a multi-line string) has an
  `end_line` greater than its `line`.
- Comments are returned in a separate list, each with a start and end position. The
  parser never sees them, so the parser's token handling does not change.
- A recovering mode records a diagnostic and continues:
  - An unexpected character is skipped.
  - An unterminated string ends at the end of its first line, so the lines after it
    still produce tokens. Today it runs to the end of the file.
- The current `tokenize` contract (return the first error) stays for callers that do
  not ask for recovery.

## Parser recovery

- A new `parser.parse_all(source)` returns `{ program, tokens, comments, diagnostics }`.
  It uses the lexer's recovering mode. `program` contains every top-level statement
  that parsed.
- `parse_program` catches the error of each top-level statement on its own. On an
  error it records the diagnostic, then resumes at the first `let`, `pub` or `type`
  token in column 1 that comes after the failed statement's first token, or at the
  end of the file.
- It resumes from the statement's start, not from where the error was found, because
  the parser does not use layout. A block is a run of `let`s followed by an
  expression, so `let x =` with nothing after it reads the top-level `let`s that
  follow as its body, and fails only later. Resuming from the error would lose those
  statements.
- When the error was found past that resume point, it is reported on the last token of
  the failed statement, as `unfinished statement: line N starts the next top-level
  statement`. Reporting it where it was found would put it far from the mistake, and
  would repeat the error of a later statement, which is parsed again and reports its
  own.
- The column-1 rule depends on top-level statements starting in column 1, which is how
  all Omelette code in the repository is written. A top-level statement that is
  indented is skipped along with the broken one before it.
- Recovery inside brackets and error nodes in the tree are out of scope. They can be
  added later without changing `parse_all`'s interface.
- A failed statement does not cause later errors at uses of its name: the type checker
  gives an unknown identifier the type `any` and reports nothing
  (`typecheck.lua:200`).

## Node ranges

- Every syntax tree node gets a range: `start_line`, `start_col`, `end_line`,
  `end_col`. The start is the node's first token; the end is the end of the last token
  the node consumed.
- The existing `line` and `col` stay as they are. They are not always the start: a
  `binop`, `pipe`, `call`, `field` or `index` node records its operator's position,
  which is where type errors point. Comprehension `generator` and `guard` nodes have
  no `line` or `col` and get only the range.
- Nodes made without consuming tokens of their own (for example `program`, or a
  `block` that takes its start from its first statement) take their range from their
  children.
- Columns count bytes, as token columns do today. Converting to the editor's column
  unit is the LSP server's job.

## Check command

- `compiler.check` uses `parse_all` and returns the parse diagnostics, then the type
  diagnostics. The type checker runs on the statements that parsed.
- `omelette check` therefore lists every syntax error in the file. Its output format
  does not change.

## Unchanged behaviour

- `parser.parse`, `compiler.compile`, `build`, `run` and the REPL still stop at the
  first error and report it as they do today.
- Generated Lua does not change.

## Tests

- Lexer: token end positions for every token kind, including a multi-line string;
  comments returned with positions; recovery after a bad character; recovery after an
  unterminated string, with the following lines lexed normally.
- Parser: two broken statements give two diagnostics, and the valid statements
  between and after them are in `program`; recovery always makes progress (a file
  that is all invalid tokens terminates).
- Node ranges: a test walks the syntax tree of every `.egg` file under `std/`,
  `spec/fixtures/` and the guide's examples. For each node it checks that the range
  exists, that the end is not before the start, and that the node's range lies inside
  its parent's range.
- Check: `omelette check` on a file with two syntax errors prints both.
