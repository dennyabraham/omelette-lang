# Omelette — Negative-Number Literal Patterns Design

**Date:** 2026-08-27
**Status:** Approved design, pre-implementation
**Roadmap item:** Now/Next — "Pattern-matching extras" (scoped to negative literals this cycle;
or-patterns and as-patterns are deferred back to the roadmap).

## Summary

Let a `match` (or any pattern position) match a negative number literal — `| -1 -> …`. Today
`-1` fails to parse in a pattern: `parse_pattern` only starts a literal on a `number` token,
but `-1` lexes as the operator `-` followed by `1`, so it falls through to the identifier path
and errors. Fix is a single parser addition; codegen and the checker are unchanged.

```egg
let sign n =
  match n with
  | -1 -> "neg one"
  | 0  -> "zero"
  | _  -> "other"
print(sign(-1))
```

## Goals

- A `-` immediately followed by a number in pattern position is a negative numeric literal
  pattern, everywhere `parse_pattern` runs (top-level arm, and nested — `[a, -1]`,
  `{ x: -1 }`).
- Negative integers and floats (`-1`, `-1.5`).

## Non-Goals (deferred)

- **Or-patterns** (`| 0 | 1 -> …`) and **as-patterns** (`p as name`) — deferred back to the
  roadmap's "Pattern-matching extras" (a later cycle).
- **Negative expressions in patterns beyond a literal** (`| -x -> …`) — a pattern matches a
  constant, not an arbitrary negated expression.
- The roadmap's other pattern items (record key-presence testing, non-linear/hygiene,
  greedy nested-form arm).

## Design

**Parser** (`parse_pattern`, `omelette/parser.lua`). Near the top — after the `wildcard`
check, before the array/record/positive-literal branches — add: if the current token is the
operator `-` and the next token (`peek2`) is a `number`, consume both and return a numeric
literal pattern with the negated value:

```lua
if self:at("op", "-") and self:peek2() and self:peek2().type == "number" then
  self:next()                 -- consume '-'
  local num = self:next()     -- the number token (num.value is a Lua number)
  return { kind = "lit", value = -num.value, lit_kind = "number" }
end
```

This yields the same `lit` node shape the positive-number branch already produces (`kind =
"lit"`, `lit_kind = "number"`), only with a negated `value`.

**Codegen — unchanged.** The existing `lit` case in `compile_pattern` emits
`expr({ kind = pat.lit_kind, value = pat.value }, ctx)`, i.e. `tostring(-1)` → the test
`access == -1`. A float `-1.5` emits `access == -1.5`. No codegen change is needed.

**Checker — unchanged.** Literal patterns do not participate in variant exhaustiveness; a
negative literal arm behaves exactly like a positive literal arm.

## Semantics

- `| -1 ->` matches the number `-1`; `| -1.5 ->` matches `-1.5`.
- Works in any pattern position because `parse_pattern` is recursive: `[a, -1]`, a record
  field pattern `{ x: -1 }`, etc.
- Only a `-` directly followed by a numeric token is a negative literal. Anything else (a `-`
  before a non-number) is untouched and continues to error as before, so no existing pattern
  changes meaning.

## Testing strategy

New `spec/negative_pattern_spec.lua`, behavioral (`compiler.eval`) unless noted:

- `match -1 with | -1 -> "a" | _ -> "b"` yields `"a"`;
- a positive value does not hit the negative arm — `match 1 with | -1 -> "a" | _ -> "b"`
  yields `"b"`;
- negative float — `match -1.5 with | -1.5 -> "a" | _ -> "b"` yields `"a"`;
- nested — `match [3, -1] with | [a, -1] -> a | _ -> 0` yields `3`;
- a `-` before a non-number still fails to parse (guard against over-broad matching) — assert
  `compiler.compile("let f x = match x with | -y -> y")` returns an error;
- emitted Lua `load()`s.

Plus one `docs/guide.md` ` ```egg ` example (CI-verified via the doctest harness), e.g. the
`sign` example above.

## File touchpoints

- **Modify:** `omelette/parser.lua` (`parse_pattern` — the negative-literal branch).
- **Create:** `spec/negative_pattern_spec.lua`.
- **Modify:** `docs/guide.md` (one verified example).
- **Unchanged:** `omelette/codegen.lua`, `omelette/typecheck.lua`, lexer, stdlib.

## Roadmap follow-ups (record in `docs/ROADMAP.md`)

- **Or-patterns** and **as-patterns** remain in "Pattern-matching extras" for a later cycle
  (with the direction/binding decisions noted: `pattern as name` ML-style; test-only
  or-patterns first).
- Mark "negative-literal patterns" done within the "Pattern-matching extras" roadmap entry on
  completion.
