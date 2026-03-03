# Critical Review: `spec/` PLT Redex Formal Semantics

**Date**: 2026-03-03
**Reviewer**: Claude Opus 4.6 (session 2026-03-03--1)
**Scope**: All files in spec/ (20 modules, ~4,430 LOC Racket, 388 tests)

## Executive Summary

This is a **competent, well-structured formal semantics** that successfully addresses the Krishnamurthi review finding "there is no specification." It covers the full preprocessing language with 388 tests across 4 sub-languages. However, it has significant issues in **formalism rigor, Redex idiom usage, and semantic faithfulness** that would concern a PL reviewer. The spec functions more as an **executable reference implementation in Redex** than a true formal semantics.

**Overall grade: B-** — solid engineering, weak formalism.

---

## 1. STRUCTURAL ISSUES (Architecture)

### 1.1 Judgment form vs. metafunction confusion

**This is the most significant problem.** The spec uses a single `define-judgment-form` for the main `eval`, but nearly all the interesting work happens in `define-metafunction` helpers (`map-items`, `map-filter-items`, `group-by-items`, `let-bind`, etc.). This inverts the PLT Redex idiom where:

- **Judgment forms** should specify relational semantics (the "what")
- **Metafunctions** should handle deterministic auxiliary computations (lookup, substitution)

The Redex FAQ explicitly says: *"Use a judgment form. Metafunctions are handy, but judgments are easier to read and debug and maintain."*

Here, the judgment form is a thin wrapper. The eval-one bridge metafunction (`eval.rkt:29-33`) exists solely to call the judgment from metafunctions, which is a code smell — it means the architectural split is wrong. The iteration helpers should themselves be judgment forms with premises that invoke `eval`, not metafunctions that escape to `judgment-holds`.

**Impact**: The relational nature of the semantics is lost. You can't compose judgments or ask "show me all derivations" because the real logic is in ordered, first-match-wins metafunctions.

### 1.2 Racket escapes (`,` unquoting) are overused

Several metafunctions escape to Racket for logic that could be expressed in Redex patterns:

- `group-by-items` (`eval.rkt:118-135`): Entirely Racket-level `let*`, `assoc`, `map`, `append`
- `dot-query` (`eval.rkt:177-192`): Racket-level `string-split`, `string-trim`, `match`
- `simple-tpl-render` (`eval.rkt:200-209`): A plain Racket function, not even a metafunction
- `val->json` (`eval.rkt:216-232`): Also a plain Racket function

When you escape to Racket, you lose:
- Redex's term validation (no grammar checking on results)
- Traceability (can't use `traces` or `stepper`)
- The specification benefit (it's just code, not math)

**`simple-tpl-render` is the worst offender** — it uses `regexp-replace*` at the Racket level, which means the template rendering rule E-Tpl is effectively "call this Racket regex function." That's an implementation, not a specification.

### 1.3 No unified language

The four sub-languages (`Iidy-Preprocess`, `Iidy-Handlebars`, `Iidy-JMESPath`, `Iidy-BracketExpansion`) all extend `Iidy-Core` independently. There's no `Iidy-Full` that composes them. This means:

- You can't write a single judgment that dispatches to sub-language evaluation
- The E-Var-J rule (var + JMESPath) can't be expressed because the JMESPath non-terminals aren't available in `Iidy-Preprocess`
- The E-Tpl rule can't dispatch to the full Handlebars renderer for the same reason

This is documented as "requires parser, outside model" but the **real** reason is the language architecture doesn't compose. A `define-union-language` or a single extended language would fix this.

---

## 2. SEMANTIC FAITHFULNESS ISSUES

### 2.1 `lookup` semantics: Quadratic and subtly wrong

The `lookup`/`lookup-or` pair (`env.rkt:24-51`) scans left-to-right, finds a match, then continues scanning right to see if there's a later shadow. This is O(n) per binding checked, O(n²) worst case.

More importantly, the comment says "right-to-left" but the implementation is left-to-right with a forward-scan-for-shadows approach. While the result is the same (rightmost wins), the spec claims one thing and implements another. A clearer specification would just reverse the list and take the first match, or scan from the right.

### 2.2 `obj-lookup` vs `lookup` semantics diverge silently

- `lookup` (env): rightmost wins (shadowing semantics)
- `obj-lookup` (objects): **leftmost** wins (first match)

This is documented (`env.rkt:129-131`) but the asymmetry is never justified or tested for conflict. What happens if an object has duplicate keys? The spec silently picks the first. Does the Haskell implementation agree? This should have a test.

### 2.3 Escape rule is incomplete

`E-Escape-Val` (`eval.rkt:462-463`) only handles values:

```racket
[--- "E-Escape-Val"
 (eval (escape v) σ v)]
```

But `escape` is supposed to suppress evaluation of **expressions** — that's its entire purpose. `(escape (var ("x")))` won't match this rule because `(var ("x"))` is not a `v`. The spec says "for non-value expressions, escape converts to a string sentinel" but **doesn't implement it**. This is a gap, not a simplification.

### 2.4 Template rendering is two different things

The spec has **two** template rendering implementations:
1. `simple-tpl-render` in `eval.rkt` — regex-based `{{path}}` substitution
2. `render-template` in `handlebars-eval.rkt` — full Handlebars AST evaluation

The E-Tpl rule uses #1, but the real Haskell implementation uses the full Handlebars engine. The simple version doesn't handle:
- Block helpers (`{{#if}}`, `{{#each}}`)
- Helper functions (`{{toLowerCase name}}`)
- Literal values (`{{"string"}}`)
- Any non-trivial Handlebars feature

This means the main evaluation judgment **doesn't compose** with the Handlebars sub-language. The spec documents this but it's a structural failure — the point of formalizing Handlebars was to connect it to the main eval.

### 2.5 Three non-executable rules

E-Var-J, E-ParseYaml/E-ParseJson, and E-Expand are specified only as comments. These represent significant language features:
- JMESPath variable queries are a primary user-facing feature
- Parse round-trips are essential for serialization correctness
- Template expansion (`!$expand`) is the module/macro system

Having 4 out of ~30 rules be non-executable (13%) is a meaningful coverage gap.

---

## 3. REDEX IDIOM ISSUES

### 3.1 Metafunction clause ordering in filter

`map-filter-items` (`eval.rkt:71-91`) relies on clause ordering: the "truthy" clause must come before the "falsy" clause because both match the same structural pattern. This is correct for metafunctions (first-match-wins) but fragile — reordering breaks it silently. Better to use a single clause with a Racket-level conditional, or express as a judgment form where the two cases are genuine inference rules.

### 3.2 `side-condition` misuse in judgment form

In `eval.rkt:287`:
```racket
(side-condition (not (equal? (term v) (term unbound))))
```

In judgment forms, `side-condition` should evaluate a **Redex expression**, not a Racket expression. This works because `not` and `equal?` are Racket forms accessible at the meta-level, but it's a mode confusion. The sentinel value approach (`unbound`) breaks Redex's type discipline — `resolve-path` returns `any`, not `v`, so the where clause binds regardless.

### 3.3 No `#:binding-forms`

The spec has binding constructs (`let`, `map` with loop variables) but doesn't use Redex's `#:binding-forms` declaration. This means:
- No capture-avoiding substitution guarantee
- No alpha-equivalence support
- The binding semantics are implemented manually via environment extension

This is acceptable for environment-passing semantics (no substitution needed), but it should be noted that the spec doesn't guarantee variable hygiene.

### 3.4 No `check-redundancy`

None of the test files enable `(check-redundancy #t)`, which would detect overlapping metafunction clauses. Given the extensive use of pattern-matching metafunctions with multiple clauses, this is a missed validation opportunity.

---

## 4. TESTING GAPS

### 4.1 Property tests are too weak

The 25 `redex-check` properties are all **totality** properties ("X always produces a Y") or **identity** properties ("X is identity on Y"). None test **interesting algebraic laws**:

| Missing property                           | Why it matters                                     |
|--------------------------------------------|----------------------------------------------------|
| Merge associativity                        | `merge(a, merge(b, c)) = merge(merge(a, b), c)`   |
| Concat associativity                       | Same                                               |
| Map distributes over concat                | `map(concat(a,b), f) = concat(map(a,f), map(b,f))`|
| Let-float equivalence                      | `let x=v in e` ≡ `e[x:=v]` when no capture        |
| Conditional excluded middle                | `if(t, a, b)` always evaluates to `a` or `b`      |
| Split/join round-trip                      | `join(d, split(d, s)) = s`                         |
| Eq symmetry                               | `eq(a,b) = eq(b,a)`                                |
| Eq transitivity                            | `eq(a,b) ∧ eq(b,c) → eq(a,c)`                     |
| Determinism                                | `eval(e, σ)` produces exactly 1 result              |

The **determinism** property is especially important — the spec claims deterministic evaluation but never tests it. The `eval-expect` helper checks `(length results) = 1` per test case, but there's no property test that checks this universally.

### 4.2 No coverage tracking

The test suite doesn't use Redex's `make-coverage`/`relation-coverage` to verify all judgment rules are exercised. With 30+ rules, it's possible some are dead code.

### 4.3 Handlebars `#each` empty-array fallthrough

`render-block "each"` (`handlebars-eval.rkt:228-243`) has three clauses:
1. Array with items → iterate
2. Object with items → iterate
3. Catch-all → render else block

The catch-all at line 243 has no guard at all — it will match **any** input, including a non-empty array if clauses 1 and 2 fail for some reason. Since metafunction clauses are ordered, this is technically correct, but the lack of an explicit falsy/empty guard means the spec doesn't clearly state *when* the else block renders.

### 4.4 JMESPath `jproj-map` clause ordering

`jproj-map` (`jmespath-eval.rkt:162-170`) relies on clause ordering for null filtering:
1. `(where null (jeval jx v_hd))` — skip nulls
2. `(where v_result (jeval jx v_hd))` — include non-nulls

Clause 2 would also match nulls (since `null` is a valid `v`). This works only because clause 1 is checked first. Fragile.

---

## 5. MINOR ISSUES

### 5.1 `val->text` for arrays/objects is non-portable

```racket
[(val->text (arr any))  ,(format "~a" (term (arr any)))]
```

This produces Racket's internal representation (e.g., `(arr ((num 1) (num 2)))`), which doesn't match the Haskell `show` output. The spec acknowledges this but it means `val->text` isn't actually faithful to the implementation for compound values.

### 5.2 `val->json` doesn't escape strings

```racket
[`(str ,s) (string-append "\"" s "\"")]
```

No escaping of `"`, `\`, or control characters. A string containing `"` would produce invalid JSON. For a specification, this is fine (it's a simplification), but it should have a comment noting the simplification.

### 5.3 JMESPath wildcard on arrays

```racket
[(jeval jwildcard (arr (v_items ...)))
 (arr (v_items ...))]
```

Per the JMESPath spec, `*` on an array should return `null`, not the array itself. Array projection uses `[*]` (different syntax). The spec may be matching iidy's behavior (which deviates from standard JMESPath), but this should be documented.

### 5.4 `truthy/hbs` and `truthy/jmespath` are identical

Lines 47-58 and 67-78 are character-for-character identical. This should be a single metafunction with an alias, or documented as intentionally separate (anticipating future divergence).

---

## 6. WHAT WORKS WELL

- **Clean grammar layering**: `Iidy-Core` → `Iidy-Preprocess` extension is textbook
- **Ordered association lists**: Correctly models insertion-order-preserving objects
- **Three truthiness variants**: Identifying and formalizing this is genuinely valuable
- **Test organization**: 10 well-structured test modules with good readability
- **Merge semantics**: The right-biased, order-preserving merge is correctly specified
- **Handlebars context merging**: `merge-context` correctly handles the obj/non-obj distinction
- **JMESPath negative indexing**: Correctly modeled with Python-style semantics
- **Group-by key ordering**: Preserves first-seen order, matching the implementation

---

## 7. RECOMMENDATIONS (prioritized)

| Priority | Issue                                      | Effort | Impact |
|----------|--------------------------------------------|--------|--------|
| **P0**   | Add determinism property test              | Low    | High   |
| **P0**   | Fix escape to handle expressions           | Medium | High   |
| **P1**   | Create `Iidy-Full` union language          | Medium | High   |
| **P1**   | Connect E-Tpl to real Handlebars renderer  | Medium | High   |
| **P1**   | Add algebraic property tests               | Medium | High   |
| **P2**   | Convert iteration helpers to judgment forms| High   | Medium |
| **P2**   | Enable `check-redundancy`                  | Low    | Medium |
| **P2**   | Add coverage tracking to test runner       | Low    | Medium |
| **P3**   | Reduce Racket escapes in metafunctions     | Medium | Low    |
| **P3**   | Document JMESPath wildcard deviation       | Low    | Low    |
| **P3**   | De-duplicate truthiness metafunctions      | Low    | Low    |

---

## Bottom Line

This spec does what it was built for — it addresses the "no specification" finding and provides a machine-checked reference for the preprocessing language. As an **engineering artifact** it's useful. As a **formal semantics** it falls short: too much Racket escape-hatch code, incomplete compositional structure, weak algebraic properties, and several non-executable rules undermine the formalism claims. A PL reviewer would say "this is a well-tested reference implementation written in Redex notation, not a formal semantics."
