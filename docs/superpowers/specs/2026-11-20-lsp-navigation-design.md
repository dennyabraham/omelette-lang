# Omelette — Hover, Definition and Symbols Design

**Date:** 2026-11-20
**Status:** Approved design, pre-implementation
**Part of:** editor support, sub-project 3 of 3. Depends on
[parsing for editors](2026-11-20-editor-parsing-design.md) and
[the LSP server](2026-11-20-lsp-server-design.md).

## Abstract

The language server gains hover, go-to-definition and document symbols, and semantic
tokens classify each use of a name by its binding. All four need to know which
declaration a name refers to. The type checker already tracks scopes as it walks the
tree, so it records that link and the type of each expression, rather than a second
walker with its own scope rules. Definitions are found within one file only.

## Contents

- [Name and type data](#name-and-type-data)
- [Node at a position](#node-at-a-position)
- [Hover](#hover)
- [Go-to-definition](#go-to-definition)
- [Document symbols](#document-symbols)
- [Semantic tokens](#semantic-tokens)
- [Release](#release)
- [Tests](#tests)

## Name and type data

- `typecheck.check(program)` also returns two tables:
  - `binding_of[use] = decl` — for each identifier use, the `let`, parameter,
    pattern variable or comprehension variable that binds it; for each type name and
    constructor, its `type` declaration.
  - `type_of[node]` — the type the checker found for each expression.
- Existing callers use only the diagnostics and do not change.
- A name the checker does not bind, such as a Lua global like `string`, has no entry.

## Node at a position

A helper finds the innermost node whose range (from sub-project 1) contains a given
position.

## Hover

- On an identifier: `name : type`. A new `format_type` prints types, for example
  `number` or `(number, string) -> boolean`.
- On a constructor: the `type` declaration it belongs to.
- The checker infers only primitive and function types, so many names have type
  `any`. In that case hover shows the source line of the declaration instead. Hover
  shows more types once optional typing cycle 2 ships.

## Go-to-definition

- Returns the range of the declaration in `binding_of`, in the same file.
- Names from other modules and Lua globals return no result. Definitions in other
  files need the server to resolve `require` paths as `searcher.lua` does; that is
  out of scope.

## Document symbols

- A top-level `let` is a `Function` symbol if it takes parameters, otherwise a
  `Variable`.
- A `type` declaration is an `Enum` symbol, with its constructors as `EnumMember`
  children.
- A symbol's range is its whole node; its selection range is its name token.

## Semantic tokens

A use of a name gets the token type of its binding: a call of `f` is `function`, a
use of a parameter is `parameter`. Uses do not get the `declaration` modifier.

## Release

- Ships in omelette 0.3.0.
- `omelette.nvim` needs no change: the client and the server agree on the features
  when the server starts.

## Tests

- `binding_of`: shadowing; pattern variables in `match` arms; comprehension variables;
  mutually recursive top-level functions; a Lua global with no entry.
- `format_type` for each type kind.
- Hover and definition at chosen positions in a fixture file, including a name with
  type `any` and a name with no binding.
- The symbol tree of a fixture file with functions, values and a sum type.
- Semantic tokens: a use of a function and a use of a parameter are classified by
  their binding.
