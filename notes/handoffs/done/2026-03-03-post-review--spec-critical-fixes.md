# PLT Redex Spec Review Fixes -- Bug-Fix / Improvement Batch

**Status**: DONE
**Date**: 2026-03-03
**Session**: 2026-03-03--1 (`e5538714-ac98-4c9f-afc6-5d853ea7bc9d`)
**References**: Critical review in this session's conversation; PLT Redex docs (docs.racket-lang.org/redex/)

## Context

A deep critical review of `spec/` identified issues ranging from
architectural (judgment form vs metafunction split) to concrete bugs
(incomplete escape rule, fragile clause ordering). The spec currently
has 388 passing tests across 20 modules.

The fixes below are prioritized by impact. P0 items are correctness
issues or missing safety checks. P1 items improve the spec's value as
a formal artifact. P2/P3 are polish.

## Issues to Fix

### P0-1: Add determinism property test

**Severity**: P0 (the spec claims determinism but never verifies it)
**File**: `spec/tests/properties.rkt`
**What's wrong**: `eval-expect` checks `(length results) = 1` per test
case, but there's no universal property test that every well-formed
expression produces exactly one eval result.
**Fix sketch**:
```racket
(test-case "eval is deterministic"
  (redex-check
    Iidy-Preprocess #:satisfying (eval e σ v) e
    (let ([results (judgment-holds (eval e σ v_out) v_out)])
      (<= (length results) 1))
    #:attempts ATTEMPTS))
```
If `#:satisfying` is too slow, generate `(e σ)` pairs from `Iidy-Preprocess`
grammar and check the property on values/simple expressions.

### P0-2: Fix escape rule to handle expressions

**Severity**: P0 (correctness gap)
**File**: `spec/semantics/eval.rkt` (line 462)
**What's wrong**: E-Escape-Val only matches `(escape v)`. Expressions
like `(escape (var ("x")))` silently produce no result. In iidy,
`!$escape` suppresses evaluation of its subtree — the whole point.
**Fix sketch**: Add a rule that converts non-value expressions to a
sentinel or their unevaluated representation:
```racket
;; E-Escape-Expr: non-value expression → unevaluated marker
;; In the real implementation, the AST is converted to raw YAML.
;; Here we evaluate normally but flag the limitation.
[(eval e σ v)
 --- "E-Escape-Expr"
 (eval (escape e) σ v)]
```
Wait — that defeats the purpose (it evaluates). The real semantics is
"convert AST to value without resolving tags." This needs thought:
either model the AST-to-raw conversion or add an E-Escape-Expr rule
that returns a `(str "!$escaped")` sentinel, with a comment explaining
the limitation. At minimum, document the gap explicitly and add a test
showing current behavior.

### P1-1: Create Iidy-Full union language

**Severity**: P1 (structural completeness)
**Files**: new file `spec/lang/full.rkt`, modifications to `spec/semantics/eval.rkt`
**What's wrong**: Sub-languages extend Iidy-Core independently, so
you can't write rules that compose them (e.g., E-Tpl dispatching to
Handlebars renderer, E-Var-J using JMESPath evaluator).
**Fix sketch**:
```racket
;; spec/lang/full.rkt
(define-extended-language Iidy-Full Iidy-Preprocess
  ;; Pull in Handlebars template AST
  (tmpl ::= (tp ...))
  (tp ::= ...)  ;; copy from handlebars.rkt
  ;; Pull in JMESPath expression AST
  (jx ::= ...)  ;; copy from jmespath.rkt
  ;; Pull in bracket expansion
  (bpath ::= ...))
```
Then redefine `eval` over `Iidy-Full`. This is a large refactor.

### P1-2: Connect E-Tpl to Handlebars renderer

**Severity**: P1 (the two template systems are disconnected)
**File**: `spec/semantics/eval.rkt` (line 481)
**What's wrong**: E-Tpl uses `simple-tpl-render` (regex-based) while
a full Handlebars renderer exists in `handlebars-eval.rkt`. They can't
compose because the languages are separate.
**Depends on**: P1-1 (Iidy-Full union language)
**Fix**: Once Iidy-Full exists, E-Tpl can call `render-template` with
the parsed template AST and `(env-to-obj σ)` as context.

### P1-3: Add algebraic property tests

**Severity**: P1 (current properties only test totality/identity)
**File**: `spec/tests/properties.rkt`
**What's wrong**: No tests for merge associativity, concat associativity,
split/join round-trip, eq symmetry, eq transitivity, conditional
excluded middle, map-concat distributivity.
**Fix sketch** (add these test cases):
```racket
(test-case "merge is associative"
  (redex-check
    Iidy-Core (obj ((k_1 v_1) ...))
    ...check merge(a, merge(b, c)) = merge(merge(a, b), c)...
    #:attempts ATTEMPTS))

(test-case "eq is symmetric"
  (redex-check
    Iidy-Core (v_1 v_2)  ;; generate two values
    (equal? (term (jcompare == v_1 v_2))
            (term (jcompare == v_2 v_1)))
    #:attempts ATTEMPTS))

(test-case "split/join round-trip"
  ;; join(d, split(d, s)) = s when d doesn't appear at string boundaries
  ...)
```

### P2-1: Enable check-redundancy

**Severity**: P2 (missed validation)
**File**: `spec/tests/run-all.rkt`
**Fix**: Add `(check-redundancy #t)` at top of test runner.

### P2-2: Add coverage tracking

**Severity**: P2 (untested rules may exist)
**File**: `spec/tests/run-all.rkt` or `spec/tests/properties.rkt`
**Fix sketch**:
```racket
(let ([cov (make-coverage eval)])
  (parameterize ([relation-coverage (list cov)])
    ;; run all eval tests
    ...)
  (for ([pair (covered-cases cov)])
    (printf "Rule ~a: ~a hits\n" (car pair) (cdr pair))))
```

### P2-3: Document JMESPath wildcard deviation

**Severity**: P2 (spec says `*` on array returns the array; JMESPath standard says null)
**File**: `spec/semantics/jmespath-eval.rkt` (line 69)
**Fix**: Add comment explaining this matches iidy's deviation from
standard JMESPath, not the official spec.

### P3-1: De-duplicate truthiness metafunctions

**Severity**: P3 (code duplication)
**File**: `spec/semantics/truthiness.rkt`
**What's wrong**: `truthy/hbs` and `truthy/jmespath` are identical.
**Fix**: Either alias one to the other or add a comment explaining
intentional duplication for future divergence.

### P3-2: Reduce Racket escapes in group-by-items

**Severity**: P3 (style — implementation not specification)
**File**: `spec/semantics/eval.rkt` (lines 117-135)
**What's wrong**: `group-by-items` is entirely Racket-level code
(let*, assoc, map, append). Hard to read as a formal rule.
**Fix**: Refactor using Redex metafunction clauses with explicit
pattern matching and helper metafunctions for group insertion.

## Codebase Reference

| What                      | Where                                    |
|---------------------------|------------------------------------------|
| Core grammar              | `spec/lang/core.rkt`                     |
| Preprocessing grammar     | `spec/lang/preprocessing.rkt`            |
| Main eval judgment        | `spec/semantics/eval.rkt` (line 242)     |
| Escape rule               | `spec/semantics/eval.rkt` (line 462)     |
| Template render (simple)  | `spec/semantics/eval.rkt` (line 200)     |
| Template render (full)    | `spec/semantics/handlebars-eval.rkt`     |
| JMESPath wildcard         | `spec/semantics/jmespath-eval.rkt` (l69) |
| Truthiness (3 variants)   | `spec/semantics/truthiness.rkt`          |
| Property tests            | `spec/tests/properties.rkt`              |
| Test runner               | `spec/tests/run-all.rkt`                 |

## Build/Test Commands

```bash
cd spec/ && nix develop
racket tests/run-all.rkt
# Expected: 388 success(es) 0 failure(s) 0 error(s)
```

## Delegation Strategy

| Issue | Delegate? | Agent    | Why                                              |
|-------|-----------|----------|--------------------------------------------------|
| P0-1  | Yes       | Sonnet   | Isolated test addition, clear spec                |
| P0-2  | No        | —        | Requires architectural judgment on escape semantics|
| P1-1  | No        | —        | Major refactor, architectural decisions            |
| P1-2  | No        | —        | Depends on P1-1, compositional design              |
| P1-3  | Yes       | Sonnet   | Isolated test additions, clear patterns            |
| P2-1  | Yes       | Sonnet   | One-line change                                    |
| P2-2  | Yes       | Sonnet   | Small addition to test runner                      |
| P2-3  | Yes       | Sonnet   | Comment addition                                   |
| P3-1  | Yes       | Sonnet   | Trivial refactor                                   |
| P3-2  | No        | —        | Requires Redex pattern design skill                |

## Workflow Instructions

- Read this file first
- Start with P0 items (determinism test, escape rule)
- P1-1 (union language) unblocks P1-2 — do them together
- P1-3 (algebraic properties) is independent
- P2/P3 items are independent of each other, do in any order
- After each fix: `racket tests/run-all.rkt` must still pass
- Update Progress below after each item

## Progress

- [x] P0-1: Add determinism property test (4 tests added)
- [x] P0-2: Fix escape rule — added escape-to-raw metafunction + 6 unit tests
- [~] P1-1: Create Iidy-Full union language — DEFERRED (see notes below)
- [~] P1-2: Connect E-Tpl to Handlebars renderer — DEFERRED (depends on P1-1)
- [x] P1-3: Add algebraic property tests (14 tests: merge assoc/commut/idempotent, eq sym/trans, concat assoc, jcompare sym, etc.)
- [x] P2-1: Enable check-redundancy in test runner
- [x] P2-2: Add coverage tracking (static — Redex API only supports reduction relations, not judgment forms)
- [x] P2-3: Document JMESPath wildcard deviation (comment added)
- [x] P3-1: Document truthiness duplication rationale (comment added)
- [x] P3-2: Refactored group-by-items — extracted insert-into-group metafunction, pure Redex patterns
- [x] Final: all 410 tests pass, committed

## Handoff Notes

### Initial Review (2026-03-03)

**Session**: 2026-03-03--1 (`e5538714-ac98-4c9f-afc6-5d853ea7bc9d`)
**Completed**: Full critical review of spec/ with PLT Redex expertise
**Key findings**:
- Spec functions more as "executable reference implementation in Redex"
  than true formal semantics — too many Racket escapes, iteration logic
  in metafunctions rather than judgment forms
- Escape rule (E-Escape-Val) only handles values, not expressions
- No determinism property test despite claiming determinism
- Sub-languages don't compose (no union language)
- E-Tpl uses regex, not the actual Handlebars renderer
- Property tests only check totality/identity, not algebraic laws
- Three truthiness variants are well done; merge/env semantics correct
**Notes for next session**: P1-1 (union language) is the biggest lift
and unblocks P1-2. Consider whether the architectural refactor is worth
it vs. documenting the limitation. P0 items are quick wins.

### Fix Implementation (2026-03-03)

**Session**: 2026-03-03--1 (`e5538714-ac98-4c9f-afc6-5d853ea7bc9d`)
**Completed**: P0-1, P0-2, P1-3, P2-3, P3-1 (6 of 10 items)
**Files modified**:
- `spec/semantics/eval.rkt` — escape-to-raw metafunction, val->json comment
- `spec/semantics/jmespath-eval.rkt` — wildcard deviation comment
- `spec/semantics/truthiness.rkt` — duplication rationale comment
- `spec/tests/eval-tests.rkt` — 6 new escape tests
- `spec/tests/properties.rkt` — 4 determinism + 14 algebraic tests
- `notes/reviews/2026-03-03-review--spec-critical.md` — full review document
**Deviations from plan**: P0-2 was more thorough than planned — implemented
full `escape-to-raw` metafunction modeling Haskell's `astToValueRaw` rather
than just documenting the gap. P3-1 kept as documentation (comment) rather
than deduplication, since the two metafunctions represent independent specs.
**Notes for next session**: Remaining items are P1-1/P1-2 (union language,
big refactor), P2-1/P2-2 (quick tooling), P3-2 (style). P2 items are
trivial one-session work. P1-1+P1-2 need architectural judgment on whether
to create a full union language or accept the current modular structure.
**Instructions for next agent**: Run tests with
`cd spec && nix develop --command racket tests/run-all.rkt` — bare `racket`
is not on PATH. Expected: 410 tests, 0 failures.

### Final Batch (2026-03-03)

**Session**: 2026-03-03--2
**Completed**: P2-1, P2-2, P3-2, P1-1/P1-2 decision (8/10 items total, 2 deferred)
**Files modified**:
- `spec/tests/run-all.rkt` — check-redundancy enabled, static coverage enumeration
- `spec/semantics/eval.rkt` — extracted `insert-into-group` metafunction from
  `group-by-items`, replacing Racket-level `let*/assoc/map/append` with pure
  Redex pattern matching (3 clauses)
**Deviations from plan**:
- P2-2 (coverage): `make-coverage` only supports reduction relations, not
  judgment forms. Implemented as static coverage enumeration (comment listing
  all 27 eval rules and which test modules exercise them) rather than runtime
  tracker. This is actually more useful as permanent documentation.
- P1-1/P1-2 (union language): DEFERRED after architectural analysis. Creating
  Iidy-Full would enable compositional rules (E-Tpl → Handlebars renderer,
  E-Var-J → JMESPath evaluator) but is ~7-8 hours of refactor for structural
  completeness. Current modular structure validates each sub-language
  independently with 410 tests. The 210 isolated sub-language tests already
  cover all Handlebars/JMESPath/bracket-expansion semantics. The limitation
  is documented: sub-languages can't compose in the eval judgment.
**Status**: All actionable items complete. Spec review fixes DONE.
