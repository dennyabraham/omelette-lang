# Docs + Site Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the ROADMAP, guide, and site into line with the five shipped Now/Next features, fixing what's stale.

**Architecture:** Three editorial workstreams over four files — ROADMAP corrections, guide weave (add missing examples into existing sections), site refresh (landing copy + playground seed). No compiler changes; the doctest harness verifies every guide ` ```egg ` block.

**Tech Stack:** Markdown (`docs/`), HTML (`site/src/`), the Lua doctest harness (`luajit spec/run.lua`).

## Global Constraints

- No compiler/stdlib changes. Only `docs/ROADMAP.md`, `docs/guide.md`, `site/src/index.html`, `site/src/play.html`.
- Every ` ```egg ` block in `docs/guide.md` is compiled/run by the suite; new blocks must pass, unchanged verified blocks stay byte-identical.
- Drop the coinage **"in-grain"** entirely (the user asked for this twice).
- Omelette has **no `rec` keyword** — recursion is via top-level forward-declaration.
- Verify: `luajit spec/run.lua` → 0 failures (doctest + site_build_spec); the new seed compiles/runs (`sum` / `6`).

---

### Task 1: ROADMAP corrections

**Files:** Modify `docs/ROADMAP.md`

- [ ] **Step 1: Move the five shipped features to the Shipped section**, deleting their Now/Next entries: Functional record update, Destructuring `let`, Tuples, Positional constructors, Negative-literal patterns. Add one terse dated line each under `## Shipped — for the record` (matching the section's style), e.g.:
  - `Functional record update — { r with f = v } (copy-and-override; shallow; works on sum-type values). (2026-08)`
  - `Tuples — (x, y) expressions + patterns, fixed-arity array sugar. (2026-08)`
  - `Destructuring let — let { x } = r / [a,b] / (a,b); irrefutable, block + top-level + pub. (2026-08)`
  - `Positional constructors — type Option = Some(a) | None; Some(3); match Some(x); arity + shape checks. (2026-08)`
  - `Negative-literal patterns — | -1 ->. (2026-08)`

- [ ] **Step 2: Remove "in-grain."** Reword the `## Now / Next` header line `language deepening (in-grain, harvestable)` to `language deepening — high-leverage, well-fitted` (or similar). Grep to confirm zero `in-grain` remain: `grep -rn "in-grain" docs/ site/ README.md` → empty.

- [ ] **Step 3: Split "Pattern-matching extras."** Negative-literal patterns shipped (Step 1); leave **or-patterns** and **as-patterns** as the remaining Now/Next entry, keeping the design notes (`pattern as name` ML-style; test-only or-patterns first).

- [ ] **Step 4: Record the parked follow-up** under Small cleanups (or beneath the positional-constructors Shipped line): `Arity-0 positional decl type E = Z() is treated by the checker as distinct from nullary (spec: Ctor() ≡ nullary) → false-positive shape-mismatch under --check on the discouraged Z() form; runtime consistent. Fix: normalize arity-0 positional → nullary in build_registry.` Also note the checker-crash-on-destructuring-let fix shipped (2026-08).

- [ ] **Step 5: Update the `_Last updated_` line** to today with a one-line summary; commit.

```bash
git add docs/ROADMAP.md
git commit -m "docs(roadmap): move 5 shipped features to Shipped; drop in-grain; record follow-ups"
```

---

### Task 2: Guide weave — add the missing examples

**Files:** Modify `docs/guide.md`

Fold the new surface into existing sections; keep unchanged ` ```egg ` blocks byte-identical. Add these verified examples with a one-line terse prose lead each, matching the guide's voice. (Positional constructors, functional update, `{ x, y }` destructuring, and the negative-`sign` example already exist from prior cycles — do NOT duplicate; just ensure the prose around them reads coherently.)

- [ ] **Step 1: Array + tuple destructuring** (Values and bindings section, near the existing record-destructuring example):

````markdown
Arrays and tuples destructure the same way:

```egg
let [first, second] = [10, 20, 30]
let (label, n)      = ("count", first + second)
print(label)
print(n)
```
```output
count
30
```
````

- [ ] **Step 2: Tuples + tuple patterns** (Pattern matching section, after the array-pattern example):

````markdown
Tuples are fixed-arity and match positionally:

```egg
let quadrant p =
  match p with
  | (0, 0) -> "origin"
  | (x, 0) -> "on the x-axis"
  | (_, _) -> "elsewhere"
print(quadrant((5, 0)))
```
```output
on the x-axis
```
````

- [ ] **Step 3: Verify coherence of the already-present examples.** Read the Sum types section: ensure both named (`Circle { radius }`) and positional (`Some(a)`/`Some(x)`) constructors have a prose lead tying them together (light edit only, no block changes). Read the records/values area: ensure the functional-update (`{ r with … }`) and destructuring examples have coherent leads.

- [ ] **Step 4: Run the doctest suite**

Run: `luajit spec/run.lua 2>&1 | tail -3`
Expected: 0 failures — the harness compiled and ran the two new ` ```egg ` blocks and matched their ` ```output ` (`count`/`30`, `on the x-axis`). If a new block fails, fix the example until it compiles and its output matches.

- [ ] **Step 5: Commit**

```bash
git add docs/guide.md
git commit -m "docs(guide): weave in array/tuple destructuring + tuple patterns"
```

---

### Task 3: Site refresh — landing copy + playground seed

**Files:** Modify `site/src/index.html`, `site/src/play.html`

- [ ] **Step 1: Landing feature bullet** (`site/src/index.html`). Replace the bullet reading `Immutable values, pattern matching, sum types, comprehensions, pipes.` with:

```html
  <li>Records with functional update, tuples, destructuring, named &amp; positional sum types, pattern matching, comprehensions, pipes.</li>
```

Leave the other `Why Omelette` bullets and the hero code block unchanged.

- [ ] **Step 2: Playground seed** (`site/src/play.html`). Replace the `<code-input id="editor" …> … </code-input>` seed content (the `type Shape = | Circle { radius } | Origin …` program) with the showcase below. **Keep the `&gt;` HTML entities** (the arrows inside `<code-input>` must be entity-escaped as in the current file):

```
type Tree = Leaf(n) | Node(l, r)

let sum t =
  match t with
  | Leaf(n)    -&gt; n
  | Node(l, r) -&gt; sum(l) + sum(r)

let tree = Node(Leaf(1), Node(Leaf(2), Leaf(3)))
let (label, total) = ("sum", sum(tree))
print(label)
print(total)
```

- [ ] **Step 3: Verify the seed compiles/runs and the build is intact**

Run:
```bash
printf 'type Tree = Leaf(n) | Node(l, r)\n\nlet sum t =\n  match t with\n  | Leaf(n)    -> n\n  | Node(l, r) -> sum(l) + sum(r)\n\nlet tree = Node(Leaf(1), Node(Leaf(2), Leaf(3)))\nlet (label, total) = ("sum", sum(tree))\nprint(label)\nprint(total)\n' > /tmp/seed_check.egg && luajit bin/omelette run /tmp/seed_check.egg
lua site/build.lua >/dev/null 2>&1 && grep -q "code-input" site/dist/play.html && echo "dist play.html OK"
luajit spec/run.lua 2>&1 | tail -1
```
Expected: prints `sum` then `6`; `dist play.html OK`; suite `0 failures` (site_build_spec still green). The playground/highlighting rendering is CI-verified by the Playwright e2e (the "prints 27" test sets its own program, and `#editor .token` works with any seed — so the seed swap is e2e-safe).

- [ ] **Step 4: Commit**

```bash
git add site/src/index.html site/src/play.html
git commit -m "docs(site): refresh landing features + playground seed for the current surface"
```

---

## Self-review notes

- Spec coverage: Task 1 = ROADMAP (workstream A); Task 2 = guide weave (B); Task 3 = site (C). All three covered.
- The seed and both new guide examples are verified to compile in Step-3/Step-4 runs.
- No compiler files touched; no new spec/test files (doctest + site_build_spec already cover the surface).
