# Omelette — Roadmap

The prioritized plan for what's next, and an honest record of what's intentionally
**out of scope**. (Formerly `DEFERRED.md`, reframed as a forward-looking roadmap.)
Each cycle's spec `Non-Goals` section remains the authoritative detail; this file is the
map so nothing gets lost between cycles.

_Last updated: 2026-08-30 — shipped the language-deepening batch (functional record update,
tuples, destructuring `let`, positional constructors, negative-literal patterns) and moved it
to Shipped; only or-/as-patterns remain of that track._

Legend: **Value** = user-visible payoff · **Effort** = build size · **Fit** = alignment
with Omelette's thesis (a small, optional/erased, *readable-Lua* ML).

---

## Now / Next — language deepening

The highest-leverage growth, much of it surfaced by comparing against Amulet and OCaml. These
are syntax + codegen + checker work — no type-theory — so they extend the language without
changing its erased, readable-output character. (Five items shipped in 2026-08 — see Shipped;
these are what remains.)

- **Pattern-matching extras (remainder)** — _Value: Medium · Effort: Low._ Negative-literal
  patterns shipped; these are the rest:
  - **Or-patterns** — `| Circle _ | Square _ ->`, `| 0 | 1 ->`. Cycle 1 = test-only
    (alternatives bind no variables).
  - **As-patterns** — `[a, b] as whole`, `Some(v) as opt` (`pattern as name`, ML-style).
  - Lower priority: record **key-presence testing** (absent fields bind `nil` by design),
    **non-linear/hygiene** (`[a, a]` is last-wins), and delimiting a **greedy nested
    `match`/`if` arm** without parentheses. _Source: 2026-08-02 pattern-matching reviews._

---

## Soon — types, checker, distribution

- **Optional typing, cycle 2** — deepen the erased checker (never blocks runtime):
  - **Collection types** `[T]` / `{ x: T }`, and typing the stdlib.
  - **Field type annotations** in sum-type declarations (`Circle { radius: number }`), then
    type `construct` / `ctor_pat` payloads against them.
  - **Bidirectional branch checking** — `if`/`match` branches currently join to `any`, so a
    knowable mismatch against a declared return type is under-reported; check branches against
    the expected type.
  - **Walk comprehension / range / dict-comp bodies** — currently synthesize to `any` without
    recursing, so an operator mismatch inside a yield is missed (never a false positive).
  - **Better function-type diagnostics** — `tyname` collapses all `fun` types to `"function"`;
    render the signature. _Source: optional-typing cycle-1 reviews._

- **Generics / parametric variants** — `type Option(a) = Some { value: a } | None`, **type
  aliases**, and **constructors as first-class function values** (construction is inlined
  today). Since types are erased, this is mostly a *checker + annotation* feature. _Value:
  Medium · Effort: Medium-High · Fit: OK — do it if you want the optional-typing story to grow._

- **Sum-type checker depth** — **Rust-strict guards** (a guarded-only constructor is
  non-exhaustive), **redundant / unreachable-arm warnings**, and a **`warning` severity** in
  the diagnostic model (today diagnostics are errors-only). _Source: sum-types designs._

- **LuaRocks: verify + publish** — now unblocked (repo is public):
  - **End-to-end verification** — exercise the rockspec's command build via a real `luarocks
    build` / `install` in CI (today it's only structurally validated). Confirm the installed
    `bin/omelette` resolves `omelette.*` / `std.*` on a clean machine (its `package.path` and
    `#!/usr/bin/env luajit` shebang are repo/luajit-oriented).
  - **Publish** — set the `LUAROCKS_API_KEY` secret; the release workflow's upload step is
    already gated on it (fires on the next tag). _Source: 2026-08-24 stdlib-distribution spec._

- **Site follow-ups** — tune the inherited **dark mode** to the OKLCH accents; a fuller
  **visual identity** (logo / favicon). _Source: docs-prose-tufte spec._

---

## Later — bigger bets & tooling

- **`--runtime-checks`** — opt-in codegen mode emitting boundary guards
  (`assert(type(x) == …)`) from annotations: the "true gradual" soundness down-payment;
  default output stays erased. _Source: typing-model decision._
- **Lambda parameter annotations** — lambdas are untyped (`any` params) today.
- **Custom operators, macros.** _Source: v1 spec._
- **Editor grammars** — TextMate / tree-sitter for VS Code / Neovim (pairs with the LSP).
  The **site highlighter + playground editor already shipped** (Prism); this is the remaining
  editor-integration piece.
- **Developer tooling** — **LSP**, a **formatter** (`eggfmt`), **`omelette test`** (a thin
  busted wrapper), **full source maps** (beyond the light `--[[omelette:LINE]]` comments).
- **Test / perf infrastructure** — **generative / property-based testing** (random token
  streams never crash the parser; every parseable program emits `load()`-able Lua; parse→emit
  is stable) and a **performance / benchmark harness** (codegen quality vs. hand-written Lua).
- **Descending ranges / custom step** — `[5 to 1]` is *empty*, not descending; no
  `[a, b .. c]` step form. _Source: range spec._

---

## Out of scope — against the grain

These fight Omelette's thesis (optional, erased, readable Lua). Adopting them would turn it
into a lesser version of a fully-typed ML like Amulet, and would sacrifice the readable
output and trivial distribution that are the point.

- **Heavy type theory** — GADTs / typed constructor signatures, type-level computation,
  dependent kinds, full Hindley-Milner inference, and **type classes with dictionary
  passing**. (If ad-hoc polymorphism is ever wanted, revisit as lightweight *protocols*, not
  a Haskell-grade class system.)
- **Index assignment** `xs[i] = v` — intentionally omitted; indexing is read-only to keep the
  surface immutable. _Source: indexing-length spec._
- **String character indexing** `s[i]` — Lua returns `nil`; use `string.sub`. (`#s` length is
  supported.) _Source: indexing-length spec._

---

## Small cleanups — non-blocking

- **Nested-IIFE indentation** — a comprehension/range nested in an indented position emits
  under-indented (but correct, runnable) Lua, because `M.expr` has no `pad` parameter.
- **Wildcard-only `match`** — `match n with | _ -> x` (no literal arms) emits a bare `else`,
  which is invalid Lua. Pathological (a wildcard-only match is pointless).
- **CLI `--out` write error** reports source position `1:1` (cosmetic).
- **Parser `at` / `peek` overshoot guard** — safe today via the lexer's EOF token; a nil-guard
  would harden it.
- **Arity-0 positional constructor vs nullary** — the checker treats `type E = Z()` as distinct
  from a bare nullary `Z` (the spec says `Ctor()` ≡ nullary), so a bare `Z` under `--check`
  gets a false-positive shape-mismatch. Only the spec-discouraged `Z()` form triggers it;
  runtime is consistent. Fix: normalize arity-0 positional → nullary in `build_registry`.

---

## Shipped — for the record

Condensed; the `CHANGELOG.md` and each cycle's spec carry the detail.

- **Core language** — lexer / parser / resolver / codegen / compiler / CLI / REPL; immutable
  values; readable Lua 5.1 output.
- **Collections** — list comprehensions, `[a to b]` ranges, key/value generators, `xs[i]`
  indexing, `#xs` length; **map-producing dict comprehensions** `{ k => v | … }` (2026-07-16).
- **Control flow** — pattern matching with destructuring + `when` guards (2026-08-02); `if`
  and `match` as first-class expressions (2026-08-07).
- **Sum types** — runtime ADTs with capitalized named-field constructors + `{ __tag }` rep
  (2026-08-08); structural exhaustiveness / construction / constructor-pattern checking
  (2026-08-11); **positional constructors** `type Option = Some(a) | None` — `Some(3)` /
  `match Some(x)`, coexisting with named + nullary, arity + shape-mismatch checks (2026-08-28).
- **Language deepening** (2026-08) — **functional record update** `{ r with f = v }` (shallow
  copy-and-override, works on sum-type values); **tuples** `(x, y)` + tuple patterns
  (fixed-arity array sugar); **destructuring `let`** — `let { x } = r` / `let [a, b] = xs` /
  `let (a, b) = t` (irrefutable; block, top-level, and `pub`); **negative-literal patterns**
  `| -1 ->`.
- **Types** — optional, erased type annotations with opt-in `omelette check` (2026-07-21).
- **Recursion** — top-level forward references / mutual recursion; `pub let` recursion-by-name.
- **Standard library** — `std.list` / `std.string` / `std.table` (incl. `merge`); **bundled
  self-contained** into the binary + a LuaRocks command build (2026-08-24).
- **Docs & site** — runnable guide (every example CI-verified, 2026-08-16); **static site +
  browser playground, published** at <https://dennyabraham.github.io/omelette-lang/>; prose +
  Tufte/OKLCH styling; **syntax highlighting** (site + playground editor, Prism).
- **Release engineering** — CI (LuaJIT + Lua 5.4); single-file amalgam with bundled typecheck;
  tag-triggered releases; **auto-tag-on-version-bump**; **Pages deploy** on push to canon.
- **Quality fixes** — literal-base field/call wrapping (`prefix()`); `searcher.install()`
  idempotency; **checker no longer crashes on destructuring `let`** (the checker assumed every
  `let` has a `.name`; now handles pattern lets, 2026-08-30).
