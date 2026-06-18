# Omelette — Language Design (v1)

**Date:** 2026-06-17
**Status:** Approved design, pre-implementation

## Summary

Omelette is a light, ML-flavored programming language that **transpiles to readable
Lua 5.1**. It is built as a *real tool* for the Lua ecosystem (Neovim, LÖVE, games,
LuaJIT), prioritizing ergonomics and **first-class two-way interop** with existing
Lua. The compiler is itself written in Lua (Fennel-style): zero external toolchain,
embeddable in any Lua host, and self-hostable later.

Source files use the **`.egg`** extension.

## Goals

- A small but complete ML-flavored language usable for real Lua-targeted programs.
- Generated Lua that is **idiomatic and human-readable** — debuggable and
  `require()`-able from plain Lua.
- Seamless interop in **both directions**: call any Lua library directly; compiled
  modules are normal Lua modules.
- Minimal friction to run: no build toolchain beyond a Lua interpreter.

## Non-Goals (v1)

- Static type checking (see "Optional types" — annotations parse but are ignored in v1).
- Currying / implicit partial application (only explicit `_` placeholders).
- Sum/variant types, exhaustiveness checking, type aliases.
- Modules-as-values, custom operators, macros.
- Full source maps; a standard library beyond passing through Lua's.
- Bundled test runner, benchmark/perf harness, formatter, LSP (documented as Future).

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Motivation | Real tool the author will use | Drives interop + ergonomics priorities |
| Type system | **Optional** annotations, checked where present | Light; types are additive, not load-bearing |
| Compiler impl language | **Lua** | Zero toolchain, embeddable, self-hostable, native to target |
| Target runtime | **Lua 5.1 baseline** | Reaches LuaJIT + Neovim; LuaJIT will not adopt 5.4 |
| v1 scope | **Thin transpiler first** | Fastest path to a usable tool; types added later |
| Lua interop | **Critical, both directions** | One `.egg` file → one idiomatic Lua module (`return M`) |
| Call/def syntax | **Style Z**: juxtaposition def headers, parenthesized calls | ML-looking definitions; clean, unambiguous calls; trivial interop |
| Partial application | **Explicit `_` placeholder** | Opt-in; multi-arg calls and Lua interop stay untouched |
| File extension | **`.egg`** | Matches the Omelette theme |

### Why Lua 5.1 baseline

LuaJIT (and therefore Neovim) is built on the Lua 5.1 language and will not adopt
5.3/5.4 — the integer subtype is fundamentally incompatible with LuaJIT's
double/NaN-boxing value model and JIT assumptions, and the project is in
maintenance mode with no roadmap toward newer versions. Targeting 5.1 reaches the
entire LuaJIT/Neovim/game world. Codegen therefore avoids: integer `//`, native
bitwise operators, `<close>` vars, and other 5.2+ features.

## Language Surface

Omelette is **expression-oriented**: `if`, `match`, and blocks all produce values.

### Syntax (Style Z)

- **Definitions** use juxtaposition headers: `let add x y = ...`
- **Calls** use parentheses, multi-arg: `add(1, 2)`
- **Lambdas** use juxtaposition params: `fn x y -> body`
- Juxtaposition appears *only* in definition/lambda headers, never in expression
  position, so there is no `f a -1` ambiguity and the parser stays simple.

```
-- a representative .egg file
let add x y = x + y                 -- file-local binding
pub let greet name =                -- pub → exported in module table
  let msg = "Hello, " .. name
  print(msg)

let inc = fn x -> x + 1             -- lambda

let describe n =                     -- expression-oriented match
  match n with
  | 0 -> "zero"
  | 1 -> "one"
  | _ -> "many"

let point = { x = 1, y = 2 }         -- record-style table
let nums  = [1, 2, 3]                -- array-style table

let total = nums |> map(inc) |> sum  -- pipe threads as first arg

let add10 = add(10, _)               -- explicit partial application
let lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)  -- Lua interop
```

### Constructs (v1)

- Bindings: `let name ... = expr`; `pub let` for exports.
- Functions: `let f x y = ...`; lambdas `fn x y -> ...`.
- `if cond then a else b` (expression).
- `match expr with | pat -> e ...` — literal and `_` patterns in v1 (compiles to
  `if/elseif/else`).
- Tables: `{ k = v }` (record/map), `[a, b]` (array). Both are plain Lua tables.
- Operators: arithmetic, comparison, `..` for string concat (matches Lua), `|>` pipe
  (threads LHS as first argument), boolean ops.
- Partial application: `f(a, _, c)` → a closure capturing the supplied args.
- Lua interop call: dotted/indexed calls pass through verbatim.
- Type annotations: **parsed and reserved, ignored in v1** (e.g. `let add (x: number) (y: number) : number = ...`).
- Raw escape hatch: a `lua "..."` form to inline literal Lua (exact syntax TBD during
  implementation) for cases codegen cannot yet express.

## Architecture & Pipeline

```
source string (.egg)
   │
   ▼
[1] lexer      → token list           (tokens carry line/col)
   │
   ▼
[2] parser     → AST                  (Pratt / precedence-climbing for expressions)
   │
   ▼
[3] resolver   → AST + scope info     (minimal in v1; reserved seam for type checker)
   │
   ▼
[4] codegen    → Lua source string    (tracks origin line per statement)
   │
   ▼
[5] driver     → file / module / REPL eval
```

### Modules (all plain Lua)

- `omelette/lexer.lua` — string → tokens
- `omelette/parser.lua` — tokens → AST (nodes are plain tables tagged with `kind`)
- `omelette/resolver.lua` — minimal scope pass; reserved seam for optional types
- `omelette/codegen.lua` — AST → Lua string
- `omelette/compiler.lua` — orchestrates stages; embeddable API
- `omelette/searcher.lua` — `package.searchers` hook to `require` `.egg` directly
- `omelette/cli.lua` — file compilation, flags, REPL entry
- `omelette/repl.lua` — read → compile → `load()` → run
- `omelette/errors.lua` — shared diagnostic type (message + line/col + snippet)

### Principles

- **AST is tagged tables** (`node.kind`) — no class machinery; easy to dispatch on in codegen.
- **Errors are values, not `error()` throws** — carry position + source snippet so the
  CLI/REPL render diagnostics instead of Lua stack traces.
- The **resolver stage exists from day one but does almost nothing in v1** — the seam
  where optional type checking later lands without restructuring the pipeline.

## Codegen & Interop Model

Guiding rule: **emit idiomatic Lua a human would write.**

| Omelette | Lua 5.1 output |
|---|---|
| `pub let add x y = ...` | `function M.add(x, y) ... end` |
| `let f x = ...` (local) | `local function f(x) ... end` |
| `let x = e` | `local x = e` |
| `fn x y -> e` | `function(x, y) return e end` |
| `add(1, _)` | `(function(a) return add(1, a) end)` |
| `a \|> f(b)` | `f(a, b)` |
| `match ... with` | `if/elseif/else` chain |
| `{ x = 1 }` / `[1,2,3]` | `{ x = 1 }` / `{ 1, 2, 3 }` |
| `a .. b` | `a .. b` |
| `vim.api.foo(x)` | `vim.api.foo(x)` (verbatim) |

### Expression-orientation over Lua statements

Omelette expressions (`if`, `match`, blocks) must yield values, but Lua's `if`/`for`
are statements. Codegen resolves this with the standard lowering:

- In **return/assignment position**, an `if`/`match` pushes its value into each branch:
  `local x = if c then a else b` → `local x; if c then x = a else x = b end`.
- A **block** (`let`s then a final expression) → statements + assignment/return of the
  final expression.
- **Never** use Lua's `(c and a or b)` idiom (breaks when `a` is falsy).

### Interop

- **Calling out:** dotted/indexed Lua calls emit verbatim; no wrapping or marshalling.
  Lua tables *are* Omelette records/arrays.
- **Being consumed:** each file → `local M = {}; ...; return M`. `pub` defines the
  surface. `require("mymod")` from plain Lua gets a normal table.
- **Require integration:** an `omelette.searcher` installed into `package.searchers`
  lets plain `require("mod")` find and compile `mod.egg` transparently — no build step
  in the loop. This is what makes Omelette a drop-in real tool in Neovim/games.
- **Raw escape hatch:** `lua "..."` to inline literal Lua when needed.

### Source mapping (v1, light)

Codegen tracks the originating line per statement and emits a `--[[omelette:LINE]]`
comment so runtime errors can be traced back. Full source maps are out of scope.

## CLI, REPL & Embedding

**CLI** (`omelette`, a thin Lua script over `compiler.lua`):

- `omelette build foo.egg` → writes `foo.lua` (or `--out dir/`)
- `omelette run foo.egg` → compile + execute in-process
- `omelette repl` → interactive
- `--ast` / `--tokens` → dump intermediate stages (developer aid)
- Non-zero exit + rendered diagnostic on error.

**REPL:** read block → `compile` → `load()` → run → print; accumulates a session
environment so `local` bindings persist across entries; renders compile diagnostics
inline.

**Embeddable API** (the real-tool seam):
`require("omelette").compile(src) -> luaSource, err` and
`.eval(src) -> value, err`, so a Neovim plugin or game can compile Omelette at runtime.

## Testing Strategy

Test-driven throughout.

- **Golden/snapshot tests** (backbone): a corpus of `*.egg` files paired with expected
  `*.lua` output — pins codegen precisely.
- **Behavioral tests:** compile + `load()` + run, assert the *result* — catches
  semantic bugs golden tests miss.
- **Unit tests per stage:** lexer (string→tokens), parser (source→AST shape), error
  cases (bad input → expected diagnostic with line/col).
- Each pipeline module is independently testable via its clean interface.

## Tooling Philosophy

Following Fennel: **don't reinvent — lean on the existing Lua ecosystem.** Because
Omelette compiles to idiomatic Lua modules, most tooling comes for free:

- **Library management:** none of our own — LuaRocks + Lua's module system. Omelette
  libraries are ordinary Lua modules, consumable from Lua and vice versa.
- **Distribution:** ship the compiler as a LuaRock / single Lua script.
- **Testing user code:** existing Lua frameworks (busted) work against compiled output.

## Future Scope (documented, not built — no stubs)

- **Optional type checking** — lands in the reserved resolver seam; annotations already parse.
- **Performance testing** — benchmark harness comparing codegen quality vs hand-written Lua.
- **`omelette test`** — thin wrapper over busted.
- **Formatter** (`eggfmt`) and **LSP** — supported by the embeddable compiler API.
- **Richer patterns / sum types / exhaustiveness**, custom operators, macros.

Reserved seams (resolver stage, embeddable `compile`/`eval` API) mean these are pure
additions, not rewrites.
