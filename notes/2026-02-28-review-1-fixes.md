# Review #1 Fixes: YAML Resolution Engine & Error Subsystem

**Date**: 2026-02-28
**Review**: `notes/2026-02-28-review-1-yaml-resolver-errors.md`
**Tests**: 469 → 561 (+92 tests)

---

## Code Fixes Applied

### Resolver.hs

| Issue | Fix | Risk |
|-------|-----|------|
| **BUG-R1**: `!!` partial function (3 sites) | `traversePathO`: replaced `length` + `!!` with `drop` + pattern match. `extractPair` in `resolveMapListToHash` and `resolveFromPairs`: replaced `length pair == 2` + `pair !! 0/1` with direct pattern match `[k, v]`. | Low — same semantics, safer. |
| **BUG-R4**: `expandBrackets` infinite loop | Added depth limit of 10 via `go` helper with decrementing counter. Returns path as-is when limit reached. | Low — 10 levels of bracket nesting is well beyond any real use case. |
| **BUG-R7**: `rawKeyText` returns `""` for non-scalar keys | Added cases for `AstBool`, `AstNull`, `AstNumber` — returns `"true"`, `"false"`, `"null"`, or the number text. Sequence/mapping keys still return `""`. | Low — only affects `astToValueRaw` (used by `!$escape`). |
| **NI-R1**: `maybe X id` → `fromMaybe` | Fixed in `buildReparse` and `fromMaybeVar`. | None. |
| **NI-R3**: `lookupO k kvs == Nothing` → `isNothing` | Fixed in `applyDotQueryValidated`. | None. |
| **NI-R2 + CS-R1**: Duplicated `resolvePair`, `isSpecialKey`, `deduplicateResources` | Extracted `resolvePairWith`, `isSpecialKey`, `deduplicateResources` as top-level functions. All 3 call sites updated. `resolveResourcesMapping` passes modified context via `resolvePairWith (ctx { tcInResourcesSection = False })`. | Medium — refactoring across 3 functions, but semantics preserved. |

### Conversion.hs

| Issue | Fix | Risk |
|-------|-----|------|
| **BUG-C1**: `T.head`/`T.tail` partial functions | Rewrote `findUnquotedComma` using `T.uncons` pattern match. Quote tracking simplified to `go (i+1) (c /= '"') rest`. | Low — same semantics, total function. |
| **BUG-C2**: Unguarded `!!` on `allLines` (8+ sites) | Added `safeLine :: [Text] -> Int -> Maybe Text` helper using `drop`+match (no `length`, no `!!`). Replaced all `allLines !! (lineNum - 1)` with `safeLine`. Rewrote `findAnyTagOnLine`, `findTagInLine`, `findAnyTagInLine`, `findVariableColumn`, `findTagOnSourceLine`, `findTagInNearbyLines` using `do`-notation with `Maybe` monad. | Low — all sites were previously guarded, now unconditionally safe. |
| **BUG-C4**: `extractFound` always returns `"wrong type"` | Added pattern matching for `"found a string"`, `"found a sequence"`, etc. Falls back to `"wrong type"`. | Low — legacy path, best-effort. |
| **CS-C4**: `isCfnValidationMessage` manual `||` chain | Replaced 11-line `||` chain with `any (\p -> p \`T.isPrefixOf\` msg) cfnValidationPrefixes`. | None. |

### Display.hs

| Issue | Fix | Risk |
|-------|-----|------|
| **SI-D1**: `getSourceLine` uses `length` + `!!` | Replaced with `drop (n - 1)` + pattern match. O(n) → O(n) but no partial functions. | None. |
| **NI-D1**: `formatSourceContext` / `formatSourceContextNoCarets` duplicated | `formatSourceContextNoCarets` now delegates to `formatSourceContext` with `spanLen=0`. Added `spanLen > 0` to `showCarets` guard. Eliminated 18 lines of copy-paste. | Low — `spanLen=0` correctly suppresses caret line. |

---

## Tests Added

| File | Tests | What |
|------|------:|------|
| `test/Test/ResolverTest.hs` | 49 | Unit tests for resolver: VarLookup (8), If (8), Let (4), Map (4), Join (4), Split (4), Merge (4), GroupBy (2), MapListToHash (4), FromPairs (3), ExpandBrackets (4) |
| `test/Test/ErrorClassificationTest.hs` | 35 | Unit tests for `classifyMessage`: all 20+ branches including unknown tag, variable not found, type mismatch, CFN validation, missing field, JMESPath, handlebars, YAML syntax, legacy type mismatches, fallback |
| `test/Test/ErrorIdTest.hs` | 6 | ErrorId round-trip, code uniqueness, positivity, unknown codes, ERR_ format, exhaustiveness |
| `test-fixtures/.../errors/expand-missing-template.yaml` | 1 | Error fixture: `!$expand` with nonexistent template |
| `test-fixtures/.../errors/expand-parse-error.yaml` | 1 | Error fixture: `!$expand` with broken template body |

**Also**: Exported `classifyMessage` from `Conversion.hs` for direct unit testing.

---

## Review False Alarms / Bad Analysis

| Issue | Claim | Reality |
|-------|-------|---------|
| **BUG-R2** | `resolveGroupBy` ignores `_templateAst` — "potential functional divergence from Rust" | **False alarm.** Rust's `resolve_group_by` also completely ignores `tag.template`. The field is parsed into the AST but never consumed in either codebase. Dead data in both. |
| **BUG-R3** | `resolveResourcesMapping` drops global sections — "silent data corruption" | **Dead code, not a live bug.** `tcInResourcesSection` is never set to `True` anywhere in the codebase. The active path is `resolveMappingWithExpansion`, which handles globals correctly. The code is vestigial (the Haskell port took a different architectural approach from Rust's path-tracker-based detection). |
| **TG-R2** | "No fixture tests for `!$expand`" | **False alarm.** `test-fixtures/example-templates/yaml-iidy-syntax/expand.yaml` exists with 3 test cases and a template import. Error fixtures were genuinely missing though — added two. |
| **BUG-R5** | CFN tag keys include `!` prefix — "relies on emitter special-casing" | **By design.** This is the intentional long-form CFN representation used throughout the pipeline. The emitter does handle these correctly. Not a bug or coupling issue. |
| **BUG-C5** | `findTagExampleForUnexpectedField` searches wrong line range — "first call is redundant" | **Mildly misleading.** The first call searches line `lineNum - 3` specifically (a common position for the tag in block-style YAML), and the fallback searches `lineNum - 5` to `lineNum`. Together they cover the full range. The overlap at line `lineNum - 3` is harmless. Not a bug. |

---

## Remaining Unfixed Issues

| Issue | Why |
|-------|-----|
| NI-C1: String-based error classification | Architectural — Rust compat requirement, would be a rewrite |
| NI-C2: `T.length "constant"` → `T.stripPrefix` | Low priority, many sites, no functional impact |
| CS-C1: Conversion.hs ~900 LOC | Splitting is a larger refactor, deferred |
| PC-C1: `T.lines source` called repeatedly | Would need threading `allLines` through all functions |
| PC-R1: O(n^2) list ops in OValue | By design (key order preservation), acceptable for CFN template sizes |
| BUG-R6: Missing CFN tag validation | Would need Rust validation rules as reference, low priority |
| Dead code: `resolveResourcesMapping` + `tcInResourcesSection` | Could be removed entirely — active path is `resolveMappingWithExpansion` |
