# PLT Redex Formal Semantics for iidy Preprocessing

## Context
Krishnamurthi review finding #2: preprocessing layer has no specification.
Building machine-readable, checkable formal grammar and operational semantics
using PLT Redex (Racket).

## Status: In Progress (Session 1 of 4 complete)

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

## Remaining

### Session 2: Iteration Tests and Properties
- [ ] More comprehensive map/iteration tests (map-f edge cases, nested ops)
- [ ] Unit tests for env metafunctions (env-tests.rkt)
- [ ] Unit tests for merge metafunctions (merge-tests.rkt)
- [ ] Property tests with `redex-check` (properties.rkt)

### Session 3: Sub-Languages
- [ ] `lang/handlebars.rkt` — Handlebars template grammar
- [ ] `semantics/handlebars-eval.rkt` — Template rendering
- [ ] `lang/jmespath.rkt` — JMESPath grammar (implemented subset)
- [ ] `semantics/jmespath-eval.rkt` — Query evaluation
- [ ] `semantics/bracket-expansion.rkt` — Dynamic path expansion
- [ ] Sub-language tests

### Session 4: Module System and Properties
- [ ] Evaluation rules for: tpl, var-q, var-j, to-yaml, parse-yaml, to-json, parse-json, expand
- [ ] `redex-check` property tests
- [ ] Final review pass: cross-reference all rules against Resolver.hs

## Key Decisions
- Language names: `Iidy-Core`, `Iidy-Preprocess` (not YAML-*)
- Environment keys are strings (YAML keys are text), not Redex symbols
- Separate `spec/flake.nix` — keeps Racket toolchain independent of Haskell flake
- Helper metafunctions for iteration (map-items, map-filter-items, etc.) instead of Racket-level for/list inside judgment forms — cleaner, more idiomatic Redex
- `escape` rule only handles values (E-Escape-Val) — full AST-to-raw conversion depends on YAML AST structure outside this model

## Review Findings Applied
- Fixed group-by-items key ordering (append new groups, don't prepend)
- Fixed val->text to handle arr/obj (was partial)
- Fixed "left-biased" comment → "rightmost wins"
- Added obj-lookup first-match vs env lookup last-match documentation
- Added iteration tests (map, map-f, concat-map, merge-map, mapListToHash, mapValues)
- Fixed escape to suppress evaluation (E-Escape-Val only matches values)
