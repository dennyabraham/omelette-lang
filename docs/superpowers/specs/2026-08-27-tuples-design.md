# Omelette — Tuples Design

**Date:** 2026-08-27
**Status:** Approved design, pre-implementation
**Roadmap item:** Now/Next — "Positional constructors + tuples" (this spec is the tuples half;
positional constructors are the sibling spec).

## Summary

Add tuple syntax — `(x, y)` expressions and `(a, b)` patterns, arity ≥ 2 — as **parser sugar
for fixed-arity arrays**. A tuple parses directly into the existing `array` expression node
and `array_pat` pattern node, so there is **no new codegen and no new pattern kind**; tuple
patterns work in `match` and in destructuring `let` for free. Chosen (Option A) over distinct
`tuple` nodes because, in Omelette's erased/dynamic surface, a 2-tuple and a 2-array are the
same Lua table — the distinction would buy nothing until a future typed cycle needs it, at
which point it can be introduced as an internal AST change invisible at the surface.

```egg
let minmax a b = if a < b then (a, b) else (b, a)
let (lo, hi)   = minmax(5, 2)                        -- once destructuring let lands; via match today
print(match minmax(5, 2) with | (lo, hi) -> hi - lo)   -- 3
```

## Goals

- `(e1, …, en)` (n ≥ 2) builds a fixed-arity array `{e1, …, en}`.
- `(p1, …, pn)` is a positional pattern usable in `match` and destructuring `let`.
- `(e)` remains grouping; existing parenthesized forms — `(match …)`, `(if …)`, `(fn …)` —
  are unchanged.
- No new AST nodes, no new codegen: tuples reuse `array` / `array_pat`.

## Non-Goals (deferred)

- **Unit `()` / 1-tuples** — nil serves for absence; a 1-tuple is just its element.
- **A distinct tuple *type*** — deferred to typed collections; if/when the type checker needs
  to tell `(number, string)` from `[number]`, introduce distinct `tuple`/`tuple_pat` nodes
  then (an internal AST change; the `(…)` surface is unaffected).
- **Trailing comma** in a tuple literal (`(a, b,)`) — not supported, matching the existing
  comma-list idiom.
- **Tuple stdlib** (`fst`/`snd`) — trivially `t[1]` / `t[2]`; add later if wanted.

## Surface & disambiguation

**Expression** (`parse_primary`, the `(` branch — parser.lua:184-192). Today: consume `(`,
`parse_expr_or_form()`, expect `)`, return the inner expression (grouping). Change: after the
inner expression, if the next token is `,`, collect the remaining comma-separated expressions
and return an `array` node; otherwise expect `)` and return the inner expression (grouping,
unchanged).

```lua
-- (e)            → e                              (grouping, unchanged)
-- (e1, e2, …)    → { kind = "array", items = { e1, e2, … } }
```

The first element stays `parse_expr_or_form()` so `(match … )` grouping is preserved; a comma
after it switches to tuple mode, collecting further elements with `parse_expr()`. No trailing
comma (the loop ends at `)`).

This cannot collide with grouping: grouping is exactly the no-comma case, which returns the
inner expression as before. `(match x with … , y)` becomes a 2-tuple of the match and `y`
(parenthesize the match if a bare grouping was intended — the existing rule).

**Pattern** (`parse_pattern`). Patterns have no grouping form today, so `(` in pattern
position is unambiguously a tuple pattern: consume `(`, collect comma-separated sub-patterns,
expect `)`, return an `array_pat`:

```lua
-- (a, b)         → { kind = "array_pat", elems = { <pat a>, <pat b> } }
```

Note the node field names differ by design in the existing AST: the `array` **expression**
node uses `items`; the `array_pat` **pattern** node uses `elems`. Tuples reuse each as-is.

## Codegen

None new. `(x, y)` is an `array` node → the existing array emission `{x, y}`. A tuple pattern
is an `array_pat` → the existing pattern compilation: in `match` it emits the `type == "table"`
+ `#access == N` length test and binds each element from `access[i]`; in destructuring `let`
(its own cycle) it flows through the array-pattern path (positional extraction, `nil` for a
missing element).

## Semantics

- **Rep** — a plain Lua array: `(1, "a")` → `{1, "a"}`, indexed `t[1]`, `t[2]`. Identical to
  an array literal; the two are interchangeable at runtime (a consequence of Option A, and
  honest to the erased surface).
- **Fixed arity at the pattern** — in `match`, a tuple pattern length-checks (via `array_pat`),
  so `| (x, y) ->` matches only a 2-element value. In destructuring `let` it is positional
  without a length check (per that cycle's semantics).
- **Nesting** — `((a, b), c)` and `(a, [b, c])` work: nested `array` / `array_pat` compose.
- **Multiple returns** — `let divmod a b = (a / b, a % b)` returns one tuple value; the caller
  destructures it (`let (q, r) = …` or `match`).

## Interaction with the other in-flight cycles

- **Destructuring `let`** — because a tuple pattern *is* an `array_pat`, `let (a, b) = pair`
  is handled by the destructuring-`let` cycle's existing array-pattern support with **no extra
  work** in either cycle. (This is the payoff of Option A: no cross-cycle coupling.)
- **Positional constructors** — independent; a constructor payload `Some(3)` is a `construct`
  node, unrelated to the tuple `(…)` expression. `Some((1, 2))` (a constructor holding a
  tuple) composes naturally.

## Testing strategy

New `spec/tuple_spec.lua`, behavioral (`compiler.eval`) unless noted:

- 2-tuple builds and indexes — `(1, 2)` yields a value with `[1] == 1`, `[2] == 2` (via a
  `match | (a, b) -> …` bind);
- 3-tuple;
- `match` with a tuple pattern, including a literal slot — `| (0, y) -> …` vs `| (x, y) -> …`;
- grouping still returns the inner value — `(1 + 2) * 3 == 9` (no comma → not a tuple);
- existing parenthesized forms unaffected — `(match … )`, `(if … )`, `(fn … )(x)`;
- nesting — `((1, 2), 3)` matched by `| ((a, b), c) -> …`;
- a `minmax`-style multiple-return (returns a tuple) destructured via `match`;
- emitted Lua `load()`s.

Plus one `docs/guide.md` ` ```egg ` example (CI-verified via the doctest harness), e.g.
`minmax` returning `(lo, hi)` matched with a tuple pattern. (Avoid integer-division examples:
Omelette's `/` is Lua 5.1 float division.)

## File touchpoints

- **Modify:** `omelette/parser.lua` — the `(` branch in `parse_primary` (tuple expression);
  `parse_pattern` (tuple pattern → `array_pat`).
- **Create:** `spec/tuple_spec.lua`.
- **Modify:** `docs/guide.md` (one verified example).
- **Unchanged:** `omelette/codegen.lua` (reuses `array` / `array_pat`), `omelette/typecheck.lua`
  (tuples synthesize as arrays → `any`, like array literals today), lexer, stdlib.

## Roadmap follow-ups (record in `docs/ROADMAP.md`)

- Distinct tuple *type* (and possibly distinct `tuple`/`tuple_pat` AST nodes) when typed
  collections land and need to separate `(A, B)` from `[A]`.
- `fst` / `snd` (or `.1` / `.2`) accessors if ergonomics call for them.
- Mark "Tuples" shipped in the roadmap's Shipped section on completion (with positional
  constructors, this closes the "Positional constructors + tuples" roadmap item).
