# Omelette — Docs + Site Refresh Design

**Date:** 2026-08-29
**Status:** Approved design, pre-implementation
**Context:** Five Now/Next features shipped (functional record update, tuples, destructuring
`let`, positional constructors, negative-literal patterns). The guide, ROADMAP, and site have
drifted; this pass corrects what's stale and weaves the new surface in.

## Summary

A documentation + site correction pass, in three workstreams: (A) fix the stale **ROADMAP**,
(B) **weave** the five features into the existing guide sections (add the missing examples,
tighten the piecemeal prose), and (C) **refresh the site** landing copy and playground seed to
reflect the current surface. No compiler changes. Every ` ```egg ` guide block stays
CI-verified by the doctest harness.

## Workstream A — ROADMAP.md corrections

1. **Move the five shipped features from "Now / Next" to "Shipped."** Functional record
   update, tuples, destructuring `let`, positional constructors, and negative-literal patterns
   currently still sit under Now/Next.
2. **Remove the "in-grain" coinage.** The "Now / Next" header reads
   *"language deepening (in-grain, harvestable)"* — reword (e.g. *"language deepening —
   high-leverage, well-fitted"*). It is the only remaining `in-grain` in the repo.
3. **Split "Pattern-matching extras."** Negative-literal patterns shipped; **or-patterns** and
   **as-patterns** remain the deferred work — keep them as the Now/Next (or Later) remainder,
   with the earlier design notes (`pattern as name` ML-style; test-only or-patterns first).
4. **Record the parked follow-up:** an arity-0 positional declaration `type E = Z()` is treated
   by the checker as distinct from nullary (spec says `Ctor()` ≡ nullary) → a false-positive
   shape-mismatch under `{ check = true }` on the discouraged `Z()` form; runtime is consistent.
   Follow-up: normalize arity-0 positional → nullary in `build_registry`. (Add under the
   positional-constructors Shipped line or Small cleanups.)

The Shipped entries are one line each, matching the section's existing terse style, with dates.

## Workstream B — guide.md weave (keep existing structure)

Fold the new surface into the current sections; add the genuinely missing examples. Existing
verified ` ```egg ` blocks stay **byte-identical**; new blocks are verified by the doctest
harness on the next `luajit spec/run.lua`.

- **Values and bindings** — introduce **destructuring `let`**: `let { x, y } = record`,
  `let [a, b] = list`, and (with tuples) `let (a, b) = pair`. (Currently only a single
  `let { x, y }` example exists; array and tuple forms are absent.)
- **Records** (in Values, or the sum-types area where records appear) — show **functional
  update** `{ r with field = v }` beside record construction, noting immutability (the original
  is untouched).
- **Tuples** — introduce `(x, y)` and tuple patterns near comprehensions/pattern-matching:
  fixed-arity, positional, `(e)` is still grouping.
- **Sum types** — cover **both** constructor shapes: named `Circle { radius }` **and**
  positional `Some(a)` / `Node(l, r)`, with positional patterns `| Some(x) ->`. (The section
  currently leads with named; positional needs first-class coverage.)
- **Pattern matching** — ensure **negative-literal patterns** (`| -1 ->`) and **tuple
  patterns** (`| (a, b) ->`) are shown (negative example exists; tuple pattern should appear).

Prose edits are tightening only — no section reordering, no rewrite. Where a new example is
added, a one-line prose lead introduces it, matching the guide's terse voice.

## Workstream C — site refresh

- **`site/src/index.html` — landing "Why Omelette" bullets.** The feature bullet currently
  reads *"Immutable values, pattern matching, sum types, comprehensions, pipes."* Update to
  reflect the fuller surface without bloating the list, e.g.:
  *"Records with functional update, tuples, destructuring, named & positional sum types,
  pattern matching, comprehensions, pipes."* Keep the other bullets (Lua 5.1 target, optional
  types, CI-verified docs) as-is. The hero code block stays a valid ` ```egg ` (unchanged, or
  optionally the new seed).
- **`site/src/play.html` — playground seed.** Replace the old named-field `Circle`/area demo
  with a showcase of the new surface (verified to compile + run → prints `sum` then `6`):

  ```egg
  type Tree = Leaf(n) | Node(l, r)

  let sum t =
    match t with
    | Leaf(n)    -> n
    | Node(l, r) -> sum(l) + sum(r)

  let tree = Node(Leaf(1), Node(Leaf(2), Leaf(3)))
  let (label, total) = ("sum", sum(tree))
  print(label)
  print(total)
  ```

  It exercises positional constructors, positional patterns, recursion via top-level
  forward-declaration (Omelette has **no `rec` keyword**), tuples, and tuple destructuring
  `let`. The seed text must keep the `&gt;` HTML entities that `play.html` uses inside
  `<code-input>`.

## Constraints & dependencies

- **Doctest:** every ` ```egg ` block in `docs/guide.md` is compiled/run by the suite; changed
  or added examples must pass. Unchanged verified blocks stay byte-identical.
- **Playground e2e:** the "Run … prints 27" test sets its own program (not the seed), and the
  `#editor .token` test works with any valid seed — so the seed change is e2e-safe. No e2e
  asserts the old seed's output.
- **Depends on the typecheck fix (PR #33):** the refreshed seed uses a tuple-destructuring
  `let`, which crashed the checker before #33. Implement this pass on a canon that includes
  #33 (rebase after it merges) so `omelette check` on the seed is safe.
- `spec/site_build_spec.lua` continues to pass (it asserts play.html references `code-input`
  and the dist file set — both unchanged by a seed swap).

## Testing

- `luajit spec/run.lua` → doctest verifies all guide ` ```egg ` blocks (new + unchanged);
  `site_build_spec` green.
- Manually build + run the new seed (`lua site/build.lua`; the seed compiles and prints
  `sum` / `6`).
- Site/playground rendering (Fengari, highlighting) is CI-verified by the Playwright e2e — the
  usual browser-only gate.

## File touchpoints

- **Modify:** `docs/ROADMAP.md`; `docs/guide.md`; `site/src/index.html`; `site/src/play.html`.
- **Unchanged:** compiler, stdlib, `site/build.lua`, `spec/site_build_spec.lua` (no new files).

## Out of scope

- Compiler changes (the arity-0 `Z()` checker Minor is recorded as a follow-up, not fixed here).
- Guide restructuring / new sections (weave into existing structure only).
- New site pages, visual-identity work (logo/favicon), dark-mode tuning — separate ROADMAP items.
