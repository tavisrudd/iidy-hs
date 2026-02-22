# Phase 7: Error Display System

**Status**: NOT STARTED
**Depends on**: Phase 2 (YAML engine), Phase 6 (test infra)
**Gate**: 49/49 error snapshots match Rust output

## Problem Statement

Enhanced error display is not wired up. Errors print as raw `Show` instances instead of the formatted output Rust produces. This is the biggest remaining gap: 0/49 error snapshots match.

## Error Format Target (from Rust snapshots)

```
Type error: msg @ file:line:col (errno: ERR_XXXX)
  -> hint

  NN | source line
     | ^^^^ pointer

  suggestion text
  For more info: iidy explain ERR_XXXX
```

## Chunks

### 7.1: Wire up EnhancedPreprocessingError conversion
- Convert `PreprocessError` → `EnhancedPreprocessingError` in Render.hs and Main.hs
- Use existing `formatError` from `Iidy.Yaml.Errors.Display`
- **Verify**: `cabal build` clean, existing 181 tests pass
- **Verify**: at least 1 error fixture now produces enhanced format

### 7.2: Fix error format to match Rust snapshots
- Compare each of 38 FAIL snapshots against Rust output
- Adjust `formatError` output to be byte-identical
- **Verify**: `scripts/error-snapshot-compare.sh` — track FAIL count decreasing

### 7.3: Fix 11 UNEXPECTED_OK validation gaps
Haskell succeeds where Rust errors. Each needs a validation check added:
- [ ] cloudformation-empty-arrays — CFN tag validation
- [ ] cloudformation-null-value — CFN tag validation
- [ ] cloudformation-wrong-element-count — CFN tag validation
- [ ] jmespath-query-and-jmespath-exclusive — mutual exclusivity check
- [ ] join-wrong-array-item-type — non-string item in !$join
- [ ] query-missing-key — missing key in query result
- [ ] tag-if-unknown-field — unknown field warnings→errors
- [ ] tag-mapvalues-unknown-field — unknown field warnings→errors
- [ ] unknown-tag-typo — typo detection for unknown !$ tags
- [ ] unknown-tag-typo-flow — typo detection for unknown !$ tags
- [ ] variable-not-found — handlebars {{var}} not in scope
- **Verify**: each fixture now errors (not UNEXPECTED_OK)

### 7.4: Final error snapshot comparison
- Run `scripts/error-snapshot-compare.sh`
- **Verify**: 49/49 PASS

## Gate Criteria
```bash
# All must pass:
cabal build 2>&1 | grep -c warning  # must be 0
cabal test                            # all tests pass
scripts/error-snapshot-compare.sh     # 49/49 PASS
scripts/snapshot-compare.sh           # 36/36 PASS (no regressions)
```
