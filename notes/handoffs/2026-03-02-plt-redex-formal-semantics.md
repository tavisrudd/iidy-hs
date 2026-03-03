# PLT Redex Formal Semantics for iidy Preprocessing

## Context
Krishnamurthi review finding #2: preprocessing layer has no specification.
Building machine-readable, checkable formal grammar and operational semantics
using PLT Redex (Racket).

## Status: Complete (4 sessions)

## Completed

### Session 1: Foundation (2026-03-02--12)
- [x] Separate `spec/flake.nix` with Racket + direnv
- [x] `lang/core.rkt` — Iidy-Core value domain (null, bool, num, str, arr, obj)
- [x] `lang/preprocessing.rkt` — Iidy-Preprocess with all 22 tag expression forms
- [x] `semantics/truthiness.rkt` — Three truthiness variants (iidy, Handlebars, JMESPath)
- [x] `semantics/env.rkt` — Environment: lookup, extend, path resolution, array indexing
- [x] `semantics/merge.rkt` — merge-objs, concat-arrs, obj-from-pairs, val->text
- [x] `semantics/eval.rkt` — Big-step eval judgment + helper metafunctions for iteration
- [x] Tests: 135 passing (grammar, truthiness, eval)
- [x] `spec/README.md`
- [x] Opus review completed with fixes applied

### Session 2: Iteration Tests and Properties (2026-03-02--13)
- [x] `tests/env-tests.rkt` — 30 unit tests (lookup, extend, resolve-path, traverse-path, obj-lookup, arr-index, env-keys)
- [x] `tests/merge-tests.rkt` — 28 unit tests (merge-objs, merge-all, concat-arrs, obj-from-pairs, val->text)
- [x] Eval tests expanded: +18 tests for group-by, concat-map-f, map-list-to-hash-f, map-values edge cases, nested/compound operations
- [x] `tests/properties.rkt` — 13 `redex-check` property tests (200 attempts each)
- [x] Bug fix: `traverse-path` missing clause for `(traverse-path () unbound)`
- [x] Exported `obj-lookup` and `arr-index` from env.rkt for direct testing
- [x] Tests: 230 passing (grammar, truthiness, env, merge, eval, properties)

### Session 3: Sub-Languages (2026-03-02--14)
- [x] `lang/handlebars.rkt` — Iidy-Handlebars grammar (template parts, expressions, block kinds)
- [x] `semantics/handlebars-eval.rkt` — Template rendering: render-template, hb-eval, hb-lookup, block helpers (if/unless/each/with), each with @index/@first/@last/@key, with context merging, helper dispatch (toLowerCase, toUpperCase, lookup, eq, length, concat)
- [x] `lang/jmespath.rkt` — Iidy-JMESPath grammar (field, index, sub, wildcard, projection, flatten, filter, multi-select, literal, pipe, identity, comparison, not)
- [x] `semantics/jmespath-eval.rkt` — Query evaluation: jeval for all 14 expression forms, projection with null filtering, filter with JMESPath truthiness, comparison operators (== != < <= > >=), negation
- [x] `semantics/bracket-expansion.rkt` — Iidy-BracketExpansion language with (bracket-ref) segments, expand-path metafunction
- [x] `tests/handlebars-tests.rkt` — 55 tests (grammar, lookup, eval, rendering, blocks, helpers, val->text)
- [x] `tests/jmespath-tests.rkt` — 47 tests (grammar, field, index, identity, wildcard, projection, flatten, filter, multi-select, pipe, comparison, negation)
- [x] `tests/bracket-expansion-tests.rkt` — 10 tests (grammar, expansion)
- [x] Tests: 346 passing (230 existing + 116 new)

### Session 4: Integration Rules and Properties (2026-03-03--1)
- [x] E-Tpl: simple {{path}} template rendering via `simple-tpl-render` Racket function
- [x] E-Var-Q: dot-query via `dot-query` metafunction (comma-separated key selection + single path traversal)
- [x] E-ToYaml: value serialization to YAML text (via val->text)
- [x] E-ToJson: value serialization to JSON text (via `val->json` Racket function)
- [x] E-Var-J: formal specification documented (requires JMESPath string parser — outside model)
- [x] E-ParseYaml, E-ParseJson: formal specification documented (round-trip property)
- [x] E-Expand: formal specification documented (requires template registry Σ)
- [x] Bridge metafunctions: `env-to-obj`, `dot-query`, `val->json`, `simple-tpl-render`
- [x] 18 new eval tests: tpl (7), var-q (4), JMESPath integration (3), serialization (12), helpers (6)
- [x] 24 new property tests (redex-check): env-to-obj, val->json, hb-val->text, hb-lookup totality; jeval identity/literal, jcompare reflexivity; bracket expansion identity; serialization totality
- [x] Tests: 388 passing (346 existing + 42 new)

## Remaining

None — formal semantics complete. Potential future work:
- JMESPath string parser (to make E-Var-J executable)
- JSON/YAML string parsers (to make E-ParseJson/E-ParseYaml executable)
- Thread template registry Σ through eval judgment (to make E-Expand executable)
- Additional property tests: composition properties, commutativity of merge

## Key Decisions
- Language names: `Iidy-Core`, `Iidy-Preprocess` (not YAML-*)
- Environment keys are strings (YAML keys are text), not Redex symbols
- Separate `spec/flake.nix` — keeps Racket toolchain independent of Haskell flake
- Helper metafunctions for iteration (map-items, map-filter-items, etc.) instead of Racket-level for/list inside judgment forms — cleaner, more idiomatic Redex
- `escape` rule only handles values (E-Escape-Val) — full AST-to-raw conversion depends on YAML AST structure outside this model
- Sub-languages extend `Iidy-Core` (not `Iidy-Preprocess`) — they share the value domain but have their own expression forms
- Handlebars context is a value, not an environment σ — template rendering traverses values directly
- Bracket expansion uses explicit `(bracket-ref)` AST form rather than string-level bracket parsing
- JMESPath subset: no slice expressions, no function calls (matching Haskell implementation)
- Helper registry is a fixed metafunction, not extensible — models iidy's closed set of helpers
- String parsing is outside the formal model — sub-languages specify evaluation after parsing
- Serialization modeled simply: to-yaml uses val->text, to-json uses a Racket JSON serializer
- Executable vs specification rules: rules requiring parsers are documented as formal specifications (inference rule notation in comments) rather than omitted
- Template registry Σ not threaded through eval judgment — expand rule documented as specification only

## Handoff Notes

### Session 4 (2026-03-03--1)
- **Files modified**: `spec/semantics/eval.rkt`, `spec/tests/eval-tests.rkt`, `spec/tests/properties.rkt`
- **Integration approach**: Executable rules for tpl/var-q/to-yaml/to-json; formal specifications (as comments) for var-j/parse-yaml/parse-json/expand. Sub-language evaluation is tested at the sub-language level; integration rules bridge the main eval judgment to sub-language semantics.
- **Cross-language calling**: Handlebars/JMESPath metafunctions are defined for their own languages (extending Iidy-Core). From eval.rkt (Iidy-Preprocess), they're called via Racket-level `,` (unquote) in judgment clauses, since Iidy-Core values are valid in all extended languages.
- **Model boundaries**: String parsing (Handlebars templates, JMESPath queries, YAML/JSON) is outside the formal model. The sub-language modules specify evaluation after parsing. Integration rules document the full pipeline as formal specifications.

### Session 3 (2026-03-02--14)
- **Files created**: `spec/lang/handlebars.rkt`, `spec/lang/jmespath.rkt`, `spec/semantics/handlebars-eval.rkt`, `spec/semantics/jmespath-eval.rkt`, `spec/semantics/bracket-expansion.rkt`, `spec/tests/handlebars-tests.rkt`, `spec/tests/jmespath-tests.rkt`, `spec/tests/bracket-expansion-tests.rkt`
- **Files modified**: `spec/tests/run-all.rkt`
- **Architecture**: Each sub-language uses `define-extended-language` extending `Iidy-Core`, so they share the value domain (v, σ) while defining their own expression forms. Handlebars context is a value (typically obj), not an environment — path lookup traverses the value directly.
- **Key design choices**:
  - Handlebars helpers modeled as fixed metafunction clauses (representative subset: toLowerCase, toUpperCase, lookup, eq, length, concat). Unknown helpers return null.
  - JMESPath projections filter out null results (matching spec). Filter uses JMESPath truthiness.
  - Bracket expansion uses explicit `(bracket-ref "var")` segments rather than string parsing — cleaner for formal model.
  - `each` over arrays provides @index/@first/@last via context merging. Objects provide @key.
- **For next session**: Session 4 hooks sub-languages into eval.rkt (E-Tpl, E-Var-Q, E-Var-J rules), adds serialization rules (to-yaml/json, parse-yaml/json), expand rule, redex-check property tests for sub-languages, and final review pass.

### Session 2 (2026-03-02--13 / bab341b4-d66f-47ed-bac7-d4f1daab5701)
- **Files modified**: `spec/semantics/env.rkt`, `spec/tests/eval-tests.rkt`, `spec/tests/run-all.rkt`
- **Files created**: `spec/tests/env-tests.rkt`, `spec/tests/merge-tests.rkt`, `spec/tests/properties.rkt`
- **Bug found**: `traverse-path` was partial — `(traverse-path () unbound)` had no matching clause. Fixed by adding explicit unbound base case before the value base case.
- **For next session**: Session 3 is sub-languages (Handlebars + JMESPath). Will need to study the Haskell implementations in `src/Iidy/Resolver.hs` for template rendering and JMESPath query semantics. The `tpl` eval rule needs Handlebars grammar first.

## Review Findings Applied
- Fixed group-by-items key ordering (append new groups, don't prepend)
- Fixed val->text to handle arr/obj (was partial)
- Fixed "left-biased" comment → "rightmost wins"
- Added obj-lookup first-match vs env lookup last-match documentation
- Added iteration tests (map, map-f, concat-map, merge-map, mapListToHash, mapValues)
- Fixed escape to suppress evaluation (E-Escape-Val only matches values)
