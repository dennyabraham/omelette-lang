# Omelette — Branch Checking Design

**Date:** 2026-11-26
**Status:** Draft, for review
**Part of:** optional typing cycle 2, sub-project 1 of 3 (then constructor field types,
then list and record types with the standard library).

## Abstract

When an `if` or `match` has branches of different types, the checker gives the whole
expression the type `any`, and `any` is consistent with every declared type. So
`let f (x: number): number = if x > 0 then x else "neg"` passes `omelette check`.

This change passes a declared type down into `if` and `match` branches and reports each
branch whose type does not fit it. The declared types are a function's return
annotation, a value annotation, and an annotated parameter receiving an argument. There
is no new syntax and nothing changes at runtime. Code with no annotations gets no new
errors.

## Contents

- [Where a declared type applies](#where-a-declared-type-applies)
- [How a branch is checked](#how-a-branch-is-checked)
- [Errors](#errors)
- [Unchanged behavior](#unchanged-behavior)
- [Editor data](#editor-data)
- [Non-goals](#non-goals)
- [Roadmap change](#roadmap-change)
- [Tests](#tests)

## Where a declared type applies

A declared type is passed into an expression in three places:

- **A function's return annotation.** In `let f (x: number): number = <body>`, the
  body is checked against `number`.
- **A value annotation.** In `let y: number = <value>`, the value is checked against
  `number`.
- **An argument to an annotated parameter.** In `g(<arg>)`, where `g` has a function
  type whose parameter is `number`, the argument is checked against `number`. This
  applies only when the call is already argument-checked today: the callee has a
  function type, the call has no `_` hole, and the argument count matches.
  - A pipe `v |> g(a)` is the call `g(v, a)`, as the checker treats it now, so `v` is
    argument 1 and is checked the same way. _(Builder's call, settled in review.)_

Lambda bodies get no declared type, because lambdas have no annotations.

## How a branch is checked

Checking an expression against a declared type `D`:

- **`if`**: the condition is checked as now. The `then` branch and the `else` branch
  are each checked against `D`.
- **`match`**: the subject, patterns and guards are handled as now. Each arm's body is
  checked against `D`. The exhaustiveness check runs as now.
- **block** (a run of `let`s and a final expression): the `let`s are checked as now. The
  final expression is checked against `D`.
- **Any other expression**: its type is found as now. If that type is not consistent
  with `D`, that is an error.

These rules nest. In
`if a then (match v with | 1 -> 1 | _ -> "x") else 2` against `number`, the error is
reported on `"x"`.

"Consistent" is the existing rule: `any` is consistent with every type, function types
compare parameter by parameter and then by return type, and other types compare by kind.

Each expression is walked once, whether it is checked against a type or not, so a type
error inside a branch is reported once.

## Errors

- **Where an error points:** at the expression that doesn't fit, not at the whole
  `let`. Every branch that doesn't fit gets its own error.
- **Message, for a branch:** `<branch> is <T>, declared <D>` for an annotation, and
  `<branch> is <T>, argument <i> expects <D>` for an argument.
  - `<branch>` is `then branch`, `else branch` or `match arm`, naming the innermost
    branch that holds the expression.
  - `<T>` and `<D>` are formatted as other type errors are, so function types print
    their signature.
- **Which message applies:** the branch message is used when an `if` or `match` lies
  between the declared type and the expression that doesn't fit. A block on that path
  doesn't count as a branch: `let f (x): number = let a = 1 "s"` (a block with no
  `if` or `match`) gets the existing return message. When the body is an `if` or
  `match`, only the branch errors are reported, with no error at the `let` as well, so
  `let f (x): number = if c then "a" else "b"` gives two errors. _(Builder's call,
  settled in review.)_
- **When no `if` or `match` is on the path:** the existing messages stay as they are.
  - `function 'f' returns <T>, declared <D>`, reported at the `let`, ahead of errors
    from inside the body.
  - `'y' is declared <D> but assigned <T>`.
  - `argument <i> expects <D>, got <T>`.
- **`nil`:** a `nil` branch against a declared type other than `nil` or `any` is an
  error. This matches the current result for `let y: number = nil`. For example,
  `let f (x: number): number = if x > 0 then x else nil` reports
  `else branch is nil, declared number`.

## Unchanged behavior

- **No declared type:** an `if` or `match` whose branches disagree gives `any` with no
  error, as now. For example, `let y = if c then 1 else "a"`.
- **Same-type branches:** an `if` or `match` whose branches all have the same type still
  has that type.
- **Declared types:** a name's type comes from its annotation, as now. A function's
  type comes from its parameter and return annotations.

## Editor data

The checker records, for the language server, the type of each expression (`type_of`)
and the declaration each name refers to (`binding_of`). Expressions checked against a
declared type are recorded the same way as the rest, so hover and go to definition work
inside branches.

## Non-goals

- New syntax, such as union types or optional types.
- Errors for branches that disagree when no type is declared.
- Expected types for lambda bodies, or a lambda's parameters inferred from the
  parameter it is passed to.
- Constructor field types, list and record types, and types for the standard library.
  These are sub-projects 2 and 3.

## Roadmap change

`docs/ROADMAP.md` gains an item in optional typing cycle 2, before list and record
types: **optional types**, such as `number?`, for a value that may be `nil`.

`std/list.egg`'s `min`, `max`, `find` and `index_of` return `nil` when there is nothing
to return. Under this design, an annotation of `number` on them is an error, so they
need optional types before the standard library is typed.

## Tests

- **`if` against a return annotation:** a wrong `else` branch is reported on that
  branch. A wrong `then` branch is reported the same way. Two wrong branches give two
  errors.
- **`match` against a return annotation:** a wrong arm is reported, and arms that fit
  are not.
- **A value annotation:** `let y: number = if c then 1 else "a"` reports on `"a"`.
- **An argument:** `g(if c then 1 else "a")`, with `g` taking a `number`, reports on
  `"a"` with the argument message. A call with a `_` hole or the wrong number of
  arguments is not checked this way.
- **Nesting:** a `match` inside an `if` branch, and a block whose final expression is an
  `if`, report on the innermost expression.
- **`nil`:** a `nil` branch against `number` is reported.
- **`any`:** a branch of type `any`, such as a call to an unannotated function, is not
  reported.
- **Unchanged:**
  - unannotated `if`/`match` with branches that disagree give no error;
  - a non-branch body keeps the existing return-mismatch message and position;
  - the standard library and the guide's examples still check clean.
- **Once only:** a type error inside a branch, such as `"a" + 1`, is reported once.
- **Editor data:** hover on a name used inside a checked branch shows its type.
