# Code Review 1c: YAML Resolver & Error Subsystem — Post-Fix Grade

**Date**: 2026-02-28
**Scope**: Resolver.hs, Context.hs, Conversion.hs, Enhanced.hs, Display.hs, Ids.hs + tests
**Context**: Grading after two rounds of review (1, 1b) and all fixes applied

## Grade: 82/100

## Issues Addressed

### Review 1 (First Review) -- Critical/Major Issues

| Issue ID  | Description                                              | Status      | Notes                                                                                      |
|:----------|:---------------------------------------------------------|:------------|:-------------------------------------------------------------------------------------------|
| BUG-R1    | Partial `!!` in Resolver.hs (3 sites)                    | FIXED       | `traversePathO` uses `drop`+match; `extractPair` uses `[k, v]` pattern match              |
| BUG-R2    | `resolveGroupBy` ignores `_templateAst`                  | FALSE ALARM | Rust also ignores it -- dead field in both codebases                                       |
| BUG-R3    | `resolveResourcesMapping` drops global sections          | FIXED       | Dead code removed entirely; `tcInResourcesSection` field also removed from Context.hs      |
| BUG-R4    | `expandBrackets` infinite loop potential                  | FIXED       | Depth limit of 10 via `go` helper with decrementing counter                                |
| BUG-R5    | CFN tag keys include `!` prefix                          | FALSE ALARM | By design; emitter handles correctly                                                       |
| BUG-R6    | Missing CFN tag validation for `!Sub`, `!GetAtt`, etc.   | FIXED       | Full validation added for `!Sub`, `!GetAtt`, `!Split`; null checks for remaining tags      |
| BUG-R7    | `rawKeyText` returns `""` for non-scalar keys            | FIXED       | Cases added for `AstBool`, `AstNull`, `AstNumber`                                          |
| BUG-C1    | `T.head`/`T.tail` partial functions                      | FIXED       | Rewritten with `T.uncons` pattern match                                                    |
| BUG-C2    | Unguarded `!!` on `allLines` (8+ sites)                  | FIXED       | `safeLine` helper using `drop`+match replaces all sites                                    |
| BUG-C4    | `extractFound` always returns `"wrong type"`             | FIXED       | Pattern matching for specific type names added                                             |
| BUG-C5    | `findTagExampleForUnexpectedField` line range            | FALSE ALARM | First call checks likely position; fallback covers full range                              |
| SI-R1     | Three uses of `!!` on lists                              | FIXED       | All eliminated (same as BUG-R1)                                                            |
| SI-D1     | `getSourceLine` uses `!!`                                | FIXED       | Uses `drop (n-1)` + pattern match now                                                      |
| NI-R1     | `maybe X id` instead of `fromMaybe`                      | FIXED       | Both sites corrected                                                                       |
| NI-R2     | Duplicated `resolvePair`, `isSpecialKey`                  | FIXED       | Extracted to top-level `resolvePairWith` and `isSpecialKey`                                 |
| NI-R3     | `lookupO k kvs == Nothing`                               | FIXED       | Changed to `isNothing`                                                                     |
| CS-R1     | `deduplicateResources` defined twice                      | FIXED       | Single shared function                                                                     |
| NI-D1     | Duplicated `formatSourceContext`/`NoCarets`               | FIXED       | `formatSourceContextNoCarets` delegates with `spanLen=0`                                   |
| CS-C4     | `isCfnValidationMessage` manual `||` chain               | FIXED       | Uses `any` over `cfnValidationPrefixes` list                                               |
| NI-C1     | String-based error classification                        | FIXED       | `ResolveErrorKind` sum type (10 variants) + smart constructors                             |
| NI-C2     | `T.drop (T.length "constant")` pattern                   | FIXED       | All 12 sites replaced with `T.stripPrefix`                                                 |
| PC-C1     | `T.lines source` called repeatedly                       | FIXED       | `classifyMessage` computes `allLines` once; threaded to helpers                            |

### Review 1b (Second Review) -- Critical/Major Issues

| Issue ID  | Description                                              | Status      | Notes                                                                                      |
|:----------|:---------------------------------------------------------|:------------|:-------------------------------------------------------------------------------------------|
| BUG-1     | Wrong value in CFN validation error messages (3 sites)   | FIXED       | All three now bind `v2` and use `oValueTypeName v2`                                        |
| DEAD-1    | `VariableSource` type completely unused                   | FIXED       | Removed from Context.hs entirely                                                           |
| DEAD-2    | `withInputUri` function never used                        | FIXED       | Removed; not present in current Context.hs                                                 |
| DEAD-3    | Dead branch in `resolveDotPathO` (`[] -> Nothing`)        | NOT FIXED   | Still present; harmless but misleading                                                     |
| PERF-1    | O(n^2) list append in resource expansion fold             | NOT FIXED   | `acc ++` still present; acceptable for CFN template sizes                                  |
| STRUCT-1  | Conversion.hs exceeds 500 LOC guideline                  | NOT FIXED   | Still ~1000 lines; acknowledged as deferred                                                |
| STYLE-1   | `_tagName` underscore on used parameter                   | NOT FIXED   | Cosmetic only                                                                              |
| STYLE-2   | `oValuesEqual` is redundant                               | NOT FIXED   | Still defined identically to `(==)`                                                        |

### Test Coverage

| Issue ID  | Description                                              | Status      | Notes                                                                                      |
|:----------|:---------------------------------------------------------|:------------|:-------------------------------------------------------------------------------------------|
| TG-R1     | Zero unit tests for resolver                              | FIXED       | 49 tests across 11 test groups in ResolverTest.hs                                          |
| TG-C1     | Zero unit tests for `classifyMessage`                     | FIXED       | 35 tests in ErrorClassificationTest.hs covering all major branches                         |
| TG-I1     | No ErrorId round-trip/uniqueness tests                    | FIXED       | 6 tests including round-trip, uniqueness, exhaustiveness                                   |
| TG-R2     | No fixture tests for `!$expand`                           | FIXED       | 2 error fixtures added; existing render fixture also noted                                 |

## Remaining Issues

**Minor -- kept deliberately:**
- `Conversion.hs` at ~1000 LOC (double the 500 LOC guideline). Explicitly deferred split.
- `acc ++` O(n^2) in `expandResources` fold. Low practical risk for typical CFN sizes.
- `_tagName` underscore prefix on used parameter. Cosmetic only.
- `oValuesEqual` redundant with `(==)`. Dead-weight code.
- Dead `[] -> Nothing` branch in `resolveDotPathO`. Unreachable since `T.splitOn` never returns `[]`.
- `resolveGroupBy` ignores `_templateAst`. Matches Rust behavior (dead data in both codebases).

**Test coverage gaps (reduced but still present):**
- 13 of 22 preprocessing tag resolvers still lack dedicated unit tests
- No CFN validation unit tests (BUG-1 was found and fixed without test regression protection)
- `findUnquotedComma` does not handle backslash-escaped quotes

## Architecture Assessment

The `ResolveErrorKind` structured error type is the most significant architectural improvement. It has 10 variants that capture semantic information at the point of error creation, eliminating the fragile string-parsing pipeline for all error types except `REGeneric`. Smart constructors enforce that each error kind carries the right data. This is a textbook Haskell pattern and a clear improvement over the original stringly-typed approach.

`classifyResolveError` now pattern-matches on `ResolveErrorKind` to produce `EnhancedPreprocessingError` directly. The 300+ line `classifyMessage'` fallback only fires for `REGeneric` (rare in practice) and YAML parse errors (no resolver context).

The `TagContext` is clean after dead code removal: three fields, with `VariableSource`, `withInputUri`, and `tcInResourcesSection` all properly eliminated.

The error display pipeline (`Enhanced.hs` -> `Display.hs`) is well-structured. The removal of `tpiCaretColumn` tightened the data model.

## Justification

**Strengths (+):**
- All critical safety violations eliminated: zero partial functions in reviewed files
- `ResolveErrorKind` structured errors are architecturally sound
- Dead code removed systematically across 3 files
- 92 new tests added (469 -> 561+), filling critical gaps
- CFN validation comprehensive: all tags validated, error messages correct
- `expandBrackets` infinite recursion fixed
- `safeLine` helper eliminates an entire class of partial-function risks
- ImportError `show` bug fixed

**Remaining weaknesses (-):**
- Conversion.hs still ~1000 LOC (-3)
- O(n^2) `acc ++` in resource expansion (-2)
- 13/22 resolver tag functions lack dedicated tests (-5)
- No CFN validation unit tests (-3)
- Minor cosmetic issues (-2)
- Resolver.hs at ~870 lines exceeds guideline (-3)
