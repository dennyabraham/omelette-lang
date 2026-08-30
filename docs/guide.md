# The Omelette Guide

Omelette is a small ML that compiles to plain Lua 5.1. Every ` ```egg ` example
below is compiled and run by the test suite (`spec/doc_guide_spec.lua`), so the
guide can't drift from the language.

Work with `.egg` files through the CLI:

- `omelette run file.egg` — compile and execute.
- `omelette build file.egg` — compile to Lua and print or write it.
- `omelette check file.egg` — type-check and report diagnostics.

## Values and bindings

`let` binds a name to a value. Names are immutable; once bound, a name can't be
reassigned. `pub let` exports the binding from its module.

```egg
let name = "Ada"
pub let greeting = "Hello, " .. name
print(greeting)
```
```output
Hello, Ada
```

## Functions and partial application

Parameters follow the name by juxtaposition — no `fn` keyword, no commas. Calls
take parens. An `_` hole leaves that argument open and yields a partially
applied function.

```egg
let add x y = x + y
let inc = add(1, _)
print(inc(4))
```
```output
5
```

## Pipes

`|>` feeds its left side as the first argument of the call on its right.

```egg
let list = require("std.list")
print([1, 2, 3] |> list.sum)
```
```output
6
```

## Control flow

`if`/`then`/`else` is an expression, not a statement. It always yields a value.

```egg
print(if 3 > 2 then "yes" else "no")
```
```output
yes
```

## Pattern matching

`match` dispatches on a value's shape: literals, variable binds, array patterns
`[a, b]`, record patterns `{ x, y }`, and `when` guards.

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

Copy a record with some fields changed — the original is untouched:

```egg
let p = { x = 1, y = 2 }
print({ p with y = 9 }.y)
```
```output
9
```

A `let` binding can destructure a record, array, or tuple directly:

```egg
let { x, y } = { x = 3, y = 4 }
print(x * y)
```
```output
12
```

Arrays and tuples bind positionally:

```egg
let [first, second] = [10, 20]
let (label, total)  = ("area", first * second)
print(label)
print(total)
```
```output
area
200
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

Parentheses with commas make a tuple, matched positionally:

```egg
let minmax a b = if a < b then (a, b) else (b, a)
print(match minmax(5, 2) with | (lo, hi) -> hi - lo)
```
```output
3
```

Number patterns can be negative:

```egg
let sign n =
  match n with
  | -1 -> "neg one"
  | 0  -> "zero"
  | _  -> "other"
print(sign(-1))
```
```output
neg one
```

## Comprehensions and ranges

`[a to b]` builds an inclusive range. List comprehensions read
`[ f(x) | x <- xs ]`; dict comprehensions, `{ k => v | k, v <- d }`.

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

A dict comprehension builds a table from `key, value` pairs:

```egg
let doubled = { k => v * 2 | k, v <- { a = 1, b = 2 } }
print(doubled.a + doubled.b)
```
```output
6
```

## Sum types

`type` declares a tagged union of constructors. A constructor carries either **named
fields** — `Circle { radius }`, built with `Circle { radius = 5 }` — or **positional
arguments** — `Some(a)`, built with `Some(3)` — or nothing at all (nullary). `match`
dispatches on the constructor.

```egg
type Option = | Some { value } | None
let unwrap opt fallback =
  match opt with
  | Some { value } -> value
  | None           -> fallback
print(unwrap(Some { value = 42 }, 0))
```
```output
42
```

Constructors can be nullary; `match` dispatches on the tag:

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

Positional constructors carry their payload by position — a natural fit for shapes like a tree:

```egg
type Tree = Leaf(n) | Node(l, r)
let sum t =
  match t with
  | Leaf(n)    -> n
  | Node(l, r) -> sum(l) + sum(r)
print(sum(Node(Leaf(1), Node(Leaf(2), Leaf(3)))))
```
```output
6
```

## Optional typing and exhaustiveness

Annotate values and signatures with `:`. `omelette check` checks the
annotations; the compiled Lua erases them.

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
'x' is declared number but assigned string
```

On a declared sum type, `match` must cover every constructor. Miss one and the
checker names it:

```egg
type Shape = | Circle { radius } | Origin
let area s = match s with | Circle { radius } -> radius
```
```error
non-exhaustive match on 'Shape': missing Origin
```

## Standard library tour

`require` loads a stdlib module by dotted path. `std.list`, `std.string`, and
`std.table` hold the common immutable operations. Each takes its collection
first: `list.map(xs, f)`, `list.sum(xs)`.

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

The full set (each takes its collection first, returns a new value):

**`std.list`** — 26 functions.
- access: `length(xs)` `is_empty(xs)` `first(xs)` `last(xs)` `get(xs, i)`
- transform: `map(xs, f)` `filter(xs, pred)` `reduce(xs, f, init)` `each(xs, f)`
- reorder: `reverse(xs)` `sort(xs)` `sort_by(xs, cmp)`
- slice: `take(xs, n)` `drop(xs, n)` `concat(a, b)` `range(a, b)`
- fold: `sum(xs)` `product(xs)` `min(xs)` `max(xs)`
- search: `all(xs, pred)` `any(xs, pred)` `count(xs, pred)` `find(xs, pred)` `contains(xs, v)` `index_of(xs, v)`

**`std.string`** — 11 functions.
- `length(s)` `upper(s)` `lower(s)` `trim(s)` `rep(s, n)`
- test: `starts_with(s, prefix)` `ends_with(s, suffix)` `contains(s, sub)`
- build: `join(xs, sep)` `split(s, sep)` `replace(s, old, new)`

**`std.table`** — 6 functions, over dicts.
- `keys(d)` `values(d)` `size(d)` `get(d, k)` `has(d, k)` `merge(a, b)`
- `merge` prefers `b` on shared keys.

```egg
let list = require("std.list")
let evens = list.filter([1, 2, 3, 4, 5, 6], fn x -> x % 2 == 0)
print(list.sum(evens))
```
```output
12
```

## Lua interop

Omelette compiles straight to Lua, so it calls Lua globals directly: `print`,
`string.*`, `table.*`, anything in scope. `lua "..."` splices raw Lua source as
an expression when you need an escape hatch.

```egg
print(string.upper("interop"))
print(lua "1 + 1")
```
```output
INTEROP
2
```
