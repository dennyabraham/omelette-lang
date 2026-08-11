# Omelette Typed Sum Types (Structural Checking) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the checker understand ADTs — a variant registry from `type` declarations, then match exhaustiveness + construction/pattern field validation (declaration names only, no field types).

**Architecture:** All in `omelette/typecheck.lua`. Task 1 builds the registry (in `M.check`, before the existing passes) and adds construction validation (`construct` synth) + constructor-pattern validation (a `validate_pattern` recursion run per match arm). Task 2 adds the exhaustiveness algorithm (`check_exhaustive`) to the `match` synth, plus the wiring/behavioral proof. All diagnostics are blocking and flow through the existing opt-in wiring unchanged (runtime paths never check).

**Tech Stack:** Pure Lua compiler, tested with the in-repo harness under `luajit`.

## Global Constraints

- Compiler source and generated Lua target the **Lua 5.1 baseline**. Test runner is `luajit spec/run.lua`.
- **Leniency:** a constructor is checked only if **declared**. Undeclared uppercase constructors → no diagnostics (lenient). A program with no `type` declarations produces no new diagnostics.
- Everything is a **blocking error** (added to `c.diags`); no new wiring — diagnostics flow through `compiler.check` / `compile(src,{check=true})` / CLI as before. Runtime `eval`/searcher/REPL never check.
- **No false positives** on existing code or the stdlib (which uses no `type` declarations).
- Guarded constructor arm **counts as covered**; only an **unguarded** top-level `var`/`wildcard` arm is a catch-all.

---

## Data Structures (authoritative reference)

Registry (stored on the checker instance):
```lua
self.types[T]       = { ctors = { <CtorName>… }, fields = { <CtorName> = { <fieldName>… } } }
self.ctor_owner[tag] = { type = <T>, fields = { <fieldName>… }, fieldset = { <fieldName> = true } }
```
Consumed nodes (from the sum-types cycle): `type_decl{ name, variants={{name, fields={…}}} }`,
`construct{ tag, fields={{key, value}} , line, col }`, `ctor_pat{ tag, fields={{key, pat}} }` (no line/col — use the enclosing `match` node for position).

---

### Task 1: Variant registry + construction/pattern validation

**Files:**
- Modify: `omelette/typecheck.lua` (add `Checker:build_registry`, `Checker:validate_pattern`; call `build_registry` in `M.check`; extend the `construct` synth; call `validate_pattern` per match arm)
- Create: `spec/typed_sumtype_validation_spec.lua`

**Interfaces:**
- Produces: `self.types` / `self.ctor_owner` on the checker (Task 2 uses them). Construction with wrong/missing/extra fields → diagnostic; a constructor pattern with an unknown field → diagnostic; undeclared → lenient.

- [ ] **Step 1: Write the failing test**

`spec/typed_sumtype_validation_spec.lua`:
```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local tc = require("omelette.typecheck")
local function diags(s) return tc.check(assert(parser.parse(s))) end
local function ok(s) h.eq(#diags(s), 0) end
local function bad(s, needle)
  local d = diags(s)
  h.truthy(#d >= 1)
  h.truthy(d[1].message:find(needle, 1, true))
end
local SHAPE = "type Shape = | Circle { radius } | Rect { width, height } | Origin\n"

h.describe("typed sum types — construction & pattern validation", function()
  h.it("correct construction is clean", function()
    ok(SHAPE .. "pub let c = Circle { radius = 5 }")
    ok(SHAPE .. "pub let o = Origin")
  end)
  h.it("unknown field in construction is flagged", function()
    bad(SHAPE .. "pub let c = Circle { radiuz = 5 }", "radiuz")
  end)
  h.it("missing field in construction is flagged", function()
    bad(SHAPE .. "pub let c = Circle {}", "missing field 'radius'")
  end)
  h.it("extra field in construction is flagged", function()
    bad(SHAPE .. "pub let c = Circle { radius = 5, color = 1 }", "color")
  end)
  h.it("undeclared constructor is lenient (no diagnostic)", function()
    ok("pub let x = Whatever { anything = 1 }")
  end)
  h.it("construction field VALUES are still checked", function()
    bad(SHAPE .. 'pub let c = Circle { radius = 1 + "oops" }', "number")
  end)
  h.it("duplicate constructor across two types is flagged", function()
    bad("type A = | Dup { x }\ntype B = | Dup { y }", "Dup")
  end)
  h.it("unknown field in a constructor pattern is flagged (top-level and nested)", function()
    bad(SHAPE .. "pub let f s = match s with | Circle { bogus } -> bogus | _ -> 0", "bogus")
    bad("type W = | Wrap { inner }\n" ..
        "pub let f v = match v with | Wrap { inner: Circle { bogus } } -> 1 | _ -> 0"
        .. "\n" .. SHAPE, "bogus")
  end)
  h.it("partial (subset) destructuring in a pattern is clean", function()
    ok(SHAPE .. "pub let f s = match s with | Rect { width } -> width | _ -> 0")
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — no registry, so field/duplicate diagnostics are absent; the `bad(...)` cases return 0 diagnostics.

- [ ] **Step 3: Implement**

In `omelette/typecheck.lua`, add two `Checker` methods (place them near the other `Checker:` methods, e.g. just before `Checker:synth`):
```lua
-- build the variant registry from all top-level type declarations
function Checker:build_registry(program)
  self.types = {}
  self.ctor_owner = {}
  for _, node in ipairs(program.stmts) do
    if node.kind == "type_decl" then
      local entry = { ctors = {}, fields = {} }
      self.types[node.name] = entry
      for _, v in ipairs(node.variants) do
        if self.ctor_owner[v.name] then
          self:err("constructor '" .. v.name .. "' declared in both '"
            .. self.ctor_owner[v.name].type .. "' and '" .. node.name .. "'", node)
        end
        entry.ctors[#entry.ctors + 1] = v.name
        entry.fields[v.name] = v.fields
        local fieldset = {}
        for _, f in ipairs(v.fields) do fieldset[f] = true end
        self.ctor_owner[v.name] = { type = node.name, fields = v.fields, fieldset = fieldset }
      end
    end
  end
end

-- validate constructor patterns anywhere in a pattern tree (declared tag → fields must be a
-- subset of the declared fields). `at` is the enclosing match node (patterns carry no line/col).
function Checker:validate_pattern(pat, at)
  local k = pat.kind
  if k == "ctor_pat" then
    local owner = self.ctor_owner[pat.tag]
    if owner then
      for _, f in ipairs(pat.fields) do
        if not owner.fieldset[f.key] then
          self:err("unknown field '" .. f.key .. "' in pattern for constructor '" .. pat.tag
            .. "' (fields: " .. table.concat(owner.fields, ", ") .. ")", at)
        end
      end
    end
    for _, f in ipairs(pat.fields) do self:validate_pattern(f.pat, at) end
  elseif k == "array_pat" then
    for _, p in ipairs(pat.elems) do self:validate_pattern(p, at) end
  elseif k == "record_pat" then
    for _, f in ipairs(pat.fields) do self:validate_pattern(f.pat, at) end
  end
end
```

Extend the `construct` case in `Checker:synth` (currently walks field values and returns ANY) to add field-key validation for a declared tag:
```lua
  if k == "construct" then
    for _, f in ipairs(node.fields) do self:synth(f.value, env) end
    local owner = self.ctor_owner and self.ctor_owner[node.tag]
    if owner then
      local provided = {}
      for _, f in ipairs(node.fields) do
        provided[f.key] = true
        if not owner.fieldset[f.key] then
          self:err("unknown field '" .. f.key .. "' for constructor '" .. node.tag
            .. "' (fields: " .. table.concat(owner.fields, ", ") .. ")", node)
        end
      end
      for _, fname in ipairs(owner.fields) do
        if not provided[fname] then
          self:err("missing field '" .. fname .. "' for constructor '" .. node.tag .. "'", node)
        end
      end
    end
    return ANY
  end
```

In the `match` case of `Checker:synth`, add a `validate_pattern` call at the top of the per-case loop (just before the `local s = scope(env)` line):
```lua
      self:validate_pattern(c.pattern, node)
```

Call `build_registry` at the very start of `M.check` (right after `local c = new_checker()`):
```lua
  c:build_registry(program)
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — construction/pattern validation tests green; all prior tests still green (stdlib + existing sum-type tests use correct/undeclared constructors → lenient or valid).

- [ ] **Step 5: Commit**

```bash
git add omelette/typecheck.lua spec/typed_sumtype_validation_spec.lua
git commit -m "feat: variant registry + construction/pattern field validation"
```

---

### Task 2: Match exhaustiveness + wiring proof

**Files:**
- Modify: `omelette/typecheck.lua` (add `Checker:check_exhaustive`; call it in the `match` synth)
- Create: `spec/typed_sumtype_exhaustive_spec.lua`

**Interfaces:**
- Consumes: `self.types` / `self.ctor_owner` (Task 1). Produces: a non-exhaustive `match` on a declared variant → blocking diagnostic; catch-all / guarded-covered / undeclared / non-variant → no diagnostic.

- [ ] **Step 1: Write the failing test**

`spec/typed_sumtype_exhaustive_spec.lua`:
```lua
local h = require("spec.support.harness")
local parser = require("omelette.parser")
local tc = require("omelette.typecheck")
local compiler = require("omelette.compiler")
local function diags(s) return tc.check(assert(parser.parse(s))) end
local function ok(s) h.eq(#diags(s), 0) end
local function bad(s, needle)
  local d = diags(s)
  h.truthy(#d >= 1)
  h.truthy(d[1].message:find(needle, 1, true))
end
local SHAPE = "type Shape = | Circle { radius } | Rect { width, height } | Origin\n"
local OPT = "type Option = | Some { value } | None\n"

h.describe("typed sum types — exhaustiveness", function()
  h.it("a complete match is clean", function()
    ok(SHAPE .. "pub let f s = match s with | Circle { radius } -> radius | Rect { width } -> width | Origin -> 0")
  end)
  h.it("a missing constructor is flagged, naming the missing ones", function()
    local d = diags(SHAPE .. "pub let f s = match s with | Circle { radius } -> radius | Origin -> 0")
    h.truthy(#d >= 1)
    h.truthy(d[1].message:find("non-exhaustive", 1, true))
    h.truthy(d[1].message:find("Rect", 1, true))
  end)
  h.it("an unguarded wildcard catch-all makes it exhaustive", function()
    ok(SHAPE .. "pub let f s = match s with | Circle { radius } -> radius | _ -> 0")
  end)
  h.it("an unguarded variable catch-all makes it exhaustive", function()
    ok(SHAPE .. "pub let f s = match s with | Circle { radius } -> radius | other -> 0")
  end)
  h.it("a guarded constructor arm counts as covered", function()
    ok(OPT .. "pub let f o = match o with | Some { value } when value > 0 -> value | None -> 0")
  end)
  h.it("a guarded-only catch-all does NOT cover (still non-exhaustive)", function()
    bad(OPT .. "pub let f o n = match o with | Some { value } -> value | x when n > 0 -> 0", "None")
  end)
  h.it("mixed-type match is flagged", function()
    bad(SHAPE .. OPT .. "pub let f v = match v with | Circle { radius } -> radius | None -> 0", "mixes")
  end)
  h.it("a non-variant (literal) match is not exhaustiveness-checked", function()
    ok('pub let f n = match n with | 0 -> "z" | 1 -> "o"')
  end)
  h.it("undeclared constructors are lenient (no exhaustiveness)", function()
    ok("pub let f v = match v with | Some { value } -> value | None -> 0")
  end)
  h.it("a complete Option match is clean; a Some-only match is flagged", function()
    ok(OPT .. "pub let f o = match o with | Some { value } -> value | None -> 0")
    bad(OPT .. "pub let f o = match o with | Some { value } -> value", "None")
  end)

  h.it("wiring: non-exhaustive match blocks check/compile-with-check but still runs at runtime", function()
    local src = OPT .. "pub let f o = match o with | Some { value } -> value"
    -- omelette check / build path: blocks
    h.truthy(#assert(compiler.check(src)) >= 1)
    local lua, err = compiler.compile(src, { check = true })
    h.truthy(lua == nil and err ~= nil)
    -- runtime path: never checks → compiles and runs
    local mod = assert(compiler.eval(src))
    h.eq(mod.f({ __tag = "Some", value = 7 }), 7)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `luajit spec/run.lua`
Expected: FAIL — no exhaustiveness check yet, so the `bad(...)` non-exhaustive/mixed cases return 0 diagnostics.

- [ ] **Step 3: Implement**

In `omelette/typecheck.lua`, add the `Checker:check_exhaustive` method (near `validate_pattern`):
```lua
-- match exhaustiveness: only over declared variants; guarded arms count as covered;
-- an unguarded top-level var/wildcard arm is a catch-all.
function Checker:check_exhaustive(node)
  local tags, seen, has_catchall = {}, {}, false
  for _, c in ipairs(node.cases) do
    local pk = c.pattern.kind
    if (pk == "var" or pk == "wildcard") and not c.guard then
      has_catchall = true
    elseif pk == "ctor_pat" then
      if not seen[c.pattern.tag] then seen[c.pattern.tag] = true; tags[#tags + 1] = c.pattern.tag end
    end
  end
  if #tags == 0 or has_catchall then return end   -- non-variant match, or covered
  local owner_type
  for _, tag in ipairs(tags) do
    local owner = self.ctor_owner[tag]
    if not owner then return end                  -- undeclared → lenient
    if owner_type == nil then
      owner_type = owner.type
    elseif owner_type ~= owner.type then
      self:err("match mixes constructors of different types ('" .. owner_type
        .. "' and '" .. owner.type .. "')", node)
      return
    end
  end
  local missing = {}
  for _, ctor in ipairs(self.types[owner_type].ctors) do
    if not seen[ctor] then missing[#missing + 1] = ctor end
  end
  if #missing > 0 then
    self:err("non-exhaustive match on '" .. owner_type .. "': missing "
      .. table.concat(missing, ", "), node)
  end
end
```

Call it in the `match` case of `Checker:synth`, right before `return ty or ANY`:
```lua
    self:check_exhaustive(node)
```

- [ ] **Step 4: Run to verify it passes**

Run: `luajit spec/run.lua`
Expected: PASS — exhaustiveness tests green (missing-ctor flagged with names; catch-all/guarded-covered/undeclared/non-variant lenient; mixed-type flagged; the wiring test proves it blocks under check but runs at runtime); all prior tests still green.

- [ ] **Step 5: Commit**

```bash
git add omelette/typecheck.lua spec/typed_sumtype_exhaustive_spec.lua
git commit -m "feat: match exhaustiveness checking for declared variants"
```

---

## Self-Review

**1. Spec coverage:**
- Variant registry (types + ctor_owner, duplicate-ctor diagnostic) → Task 1 `build_registry`. ✓
- Construction validation (missing/extra/misspelled; field values still walked; undeclared lenient) → Task 1 `construct` synth. ✓
- Pattern validation (unknown field, top-level + nested; subset allowed; undeclared lenient) → Task 1 `validate_pattern`. ✓
- Exhaustiveness (collect tags; catch-all; guarded-covered; undeclared skip; mixed-type; missing-list) → Task 2 `check_exhaustive`. ✓
- Blocking + opt-in wiring; runtime never checks → Task 2 wiring test (uses existing `compiler.check`/`compile`/`eval`). ✓
- No false positives; stdlib clean → both tasks (undeclared/non-variant lenient; empty registry when no decls). ✓
- Deferred (field types, generics, Rust-strict guards, warnings) → not implemented (correct). ✓

No gaps.

**2. Placeholder scan:** No "TBD"/"TODO". Complete method bodies + full test assertions in every step. Diagnostic message substrings in tests are pinned to the exact `self:err(...)` strings.

**3. Type consistency:** `build_registry` populates `self.types`/`self.ctor_owner`; `construct` synth, `validate_pattern`, and `check_exhaustive` read them with the exact shapes defined above (`owner.fieldset`, `owner.fields`, `owner.type`, `self.types[T].ctors`). `self:err(msg, node)` uses `node.line/col` with a 1,1 fallback, so passing the `match` node for position-less `ctor_pat`s is safe. `construct` nodes carry `line`/`col`. The registry is built before both `M.check` passes, so forward references resolve. ✓
