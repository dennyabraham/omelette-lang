# The Omelette Guide

Omelette is a small ML-flavored language that compiles to readable Lua 5.1. Every
` ```egg ` example in this guide is compiled and run by the test suite (see
`spec/doc_guide_spec.lua`), so what you read here is what actually happens.

Use the CLI to work with `.egg` files directly:

- `omelette run file.egg` — compile and execute.
- `omelette build file.egg` — compile to Lua and print (or write) the output.
- `omelette check file.egg` — run the type checker and report diagnostics.

## Values and bindings

`let` binds a name to a value. Bindings are immutable — once bound, a name can't
be reassigned. `pub let` exports the binding from the module.

```egg
let name = "Ada"
pub let greeting = "Hello, " .. name
print(greeting)
```
```output
Hello, Ada
```

## Functions and partial application

Function headers use juxtaposition for parameters — no `fn`/`function` keyword,
no commas. Calls use parens. An `_` hole in a call leaves that argument open,
producing a partially-applied function.

```egg
let add x y = x + y
let inc = add(1, _)
print(inc(4))
```
```output
5
```

## Pipes

`|>` threads its left-hand side in as the first argument of the call on its
right.

```egg
let list = require("std.list")
print([1, 2, 3] |> list.sum)
```
```output
6
```

## Control flow

`if`/`then`/`else` is an expression, not a statement — it always produces a
value.

```egg
print(if 3 > 2 then "yes" else "no")
```
```output
yes
```

## Pattern matching

`match` dispatches on a value's shape: literals, variable binds, array
`[a, b]` patterns, record `{ x, y }` patterns, and `when` guards.

```egg
let describe pt =
  match pt with
  | { x, y } when x == y -> "diagonal"
  | { x, y } when x == 0 -> "on y-axis"
  | { x, y }             -> "off-axis"
print(describe({ x = 1, y = 1 }))
```
```output
diagonal
```

Array patterns discriminate by length:

```egg
let sum_first_two v =
  match v with
  | [a]    -> a
  | [a, b] -> a + b
  | _      -> 0
print(sum_first_two([3, 4]))
```
```output
7
```

## Comprehensions and ranges

`[a to b]` builds an inclusive range. List comprehensions have the shape
`[ f(x) | x <- xs ]`, and dict comprehensions `{ k => v | k, v <- d }`.

```egg
let list = require("std.list")
print(list.length([ x * x | x <- [1 to 3] ]))
```
```output
3
```

A comprehension can filter with a trailing condition:

```egg
let list = require("std.list")
print(list.sum([ x | x <- [1 to 10], x > 5 ]))
```
```output
40
```

Dict comprehensions build a new table from `key, value` pairs:

```egg
let doubled = { k => v * 2 | k, v <- { a = 1, b = 2 } }
print(doubled.a + doubled.b)
```
```output
6
```

## Sum types

`type` declares a tagged union of constructors, each with an optional
record of fields. Construct a value with `Ctor { field = v }`; match on it
with a constructor pattern.

```egg
type Option = | Some { value } | None
let unwrap opt fallback = match opt with | Some { value } -> value | None -> fallback
print(unwrap(Some { value = 42 }, 0))
```
```output
42
```

Constructors can be nullary, and `match` dispatches on the tag:

```egg
type Shape = | Circle { radius } | Rect { width, height } | Origin
let area s =
  match s with
  | Circle { radius }      -> 3 * radius * radius
  | Rect { width, height } -> width * height
  | Origin                 -> 0
print(area(Circle { radius = 2 }) + area(Origin))
```
```output
12
```

## Optional typing and exhaustiveness

Annotate values and function signatures with `:`. Annotations are checked by
`omelette check` but erased from the compiled Lua.

```egg
let add (x: number) (y: number): number = x + y
print(add(2, 3))
```
```output
5
```

A mismatched annotation is a type error:

```egg
let x: number = "hi"
```
```error
number
```

For a value of a declared sum type, `match` must cover every constructor —
missing one is a checker error naming the missing constructor:

```egg
type Shape = | Circle { radius } | Origin
let area s = match s with | Circle { radius } -> radius
```
```error
non-exhaustive match on 'Shape': missing Origin
```

## Standard library tour

`require` loads a stdlib module by dotted path. `std.list`, `std.string`, and
`std.table` cover the common collection-first, immutable operations —
`list.map(xs, f)`, `list.sum(xs)`, and friends take the collection first.

```egg
let list = require("std.list")
let str = require("std.string")
let tbl = require("std.table")
print(list.sum([1, 2, 3]))
print(str.upper("hi"))
print(tbl.size({ a = 1, b = 2 }))
```
```output
6
HI
2
```

`std.list` also has `map`, `filter`, `reduce`, `reverse`, `sort`, `find`,
`take`/`drop`, and more; `std.string` has `split`, `join`, `trim`,
`starts_with`/`ends_with`; `std.table` has `keys`, `values`, `has`, `merge`.

```egg
let list = require("std.list")
let evens = list.filter([1, 2, 3, 4, 5, 6], fn x -> x % 2 == 0)
print(list.sum(evens))
```
```output
12
```

## Lua interop

Omelette code can call Lua globals directly — `print`, `string.*`,
`table.*`, and anything else in scope — since it compiles straight to Lua.
`lua "..."` splices raw Lua source in as an expression when you need an
escape hatch.

```egg
print(string.upper("interop"))
print(lua "1 + 1")
```
```output
INTEROP
2
```
