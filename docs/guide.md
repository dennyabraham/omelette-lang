# The Omelette Guide

Omelette is a small ML-flavored language that compiles to Lua 5.1.

## Values and functions

```egg
let add x y = x + y
print(add(2, 3))
```
```output
5
```

## Pattern matching

```egg
let describe n =
  match n with
  | 0 -> "zero"
  | _ -> "many"
print(describe(0))
```
```output
zero
```

## Exhaustiveness

The type checker rejects a `match` that misses a constructor:

```egg
type Shape = | Circle { radius } | Origin
let area s = match s with | Circle { radius } -> radius
```
```error
non-exhaustive match on 'Shape': missing Origin
```
