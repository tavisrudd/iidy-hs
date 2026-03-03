# Code Review: YAML Resolution Engine & Error Subsystem

**Reviewer:** Claude Opus 4.6
**Date:** 2026-02-28
**Scope:** Resolver.hs, Conversion.hs, Display.hs, Ids.hs + test coverage

---

## 1. Resolver.hs (812 lines)

### 1.1 Bugs and Correctness Issues

**BUG-R1: Partial list indexing with `!!` (lines 466, 633, 684)**

Three uses of `!!` on lists, which is a partial function that crashes on out-of-bounds access:

```haskell
-- Line 466
[(i, "")] | i >= 0 && i < length arr -> traversePathO rest (arr !! i)

-- Lines 633, 684
| length pair == 2 = pure (oValueToText (pair !! 0), pair !! 1)
```

The line 466 case *is* guarded by a bounds check, but `length` + `!!` on a list is O(n) + O(n) — see the performance section. More critically, lines 633 and 684 use `length pair == 2` as a guard, which is safe in practice, but the pattern is fragile and non-idiomatic. A pattern match would be both safer and clearer:

```haskell
-- Preferred:
extractPair (OArray [k, v]) = pure (oValueToText k, v)
```

**BUG-R2: `resolveGroupBy` ignores the `_templateAst` field (line 657)**

```haskell
resolveGroupBy ctx meta (GroupByTag itemsAst keyAst var _templateAst) = do
```

The `_templateAst` parameter (the `template` field from `!$groupBy`) is silently ignored. The function groups items by key but never applies a template transformation to the grouped results. If the Rust source applies a template per-group, this is a functional divergence. If not, the AST type carries dead data.

**BUG-R3: `resolveMapping` drops resources section globals (line 189-201)**

In `resolveResourcesMapping`, expanded custom resources' global sections (e.g., `Conditions`, `Outputs`) are silently discarded. The `expandIfCustom` function only collects resources, not global sections. Compare with `resolveMappingWithExpansion` (line 112-125) which does merge globals. If `resolveResourcesMapping` is the active path when `tcInResourcesSection` is true, global sections from custom resources are lost.

**BUG-R4: `expandBrackets` infinite loop potential (lines 432-446)**

```haskell
expandBrackets path ctx
  | T.isInfixOf "[" path =
      let (before, rest) = T.breakOn "[" path
          (varName, after) = T.breakOn "]" (T.drop 1 rest)
          ...
          expanded = before <> "." <> resolved <> suffix
      in expandBrackets expanded ctx  -- recursive call
```

If the variable resolution itself produces text containing `[`, this function recurses indefinitely. For example, if variable `x` has value `"a[b"`, then `path[x]` expands to `path.a[b`, which triggers another expansion attempt. This would result in an infinite loop or stack overflow. The Rust version likely handles this via iterative expansion or by tracking depth.

**BUG-R5: `resolveCfnTag` wraps output with `!` prefix (line 306)**

```haskell
resolveCfnTag ctx meta tag = do
  let (name, inner) = cfnTagParts tag
  resolved <- resolveAst ctx inner
  validateCfnTag meta name resolved
  pure $ OObject [(name, resolved)]
```

The `name` from `cfnTagParts` includes `!` (e.g., `"!Ref"`, `"!Sub"`). This means the output OObject has keys like `"!Ref"` which is correct for CFN long-form — but note the inconsistency: when emitted as YAML, this relies on the emitter recognizing these `!`-prefixed keys and converting them to short-form tags. If the emitter doesn't special-case these, the output YAML will have literal `!Ref:` mapping keys rather than `Ref:` under `Fn::Ref`.

**BUG-R6: `validateCfnTag` incomplete — missing `!Sub` and `!GetAtt` validation (lines 309-350)**

`!Sub` and `!GetAtt` have no validation. `!Sub` accepts either a string or a 2-element array `[template, {var: value}]`. `!GetAtt` accepts a string `"Resource.Attribute"` or a 2-element array. The validator falls through to `_ -> pure ()` for these, allowing malformed input.

Additionally, `!Cidr`, `!Length`, `!ToJsonString`, `!Transform`, `!ForEach`, `!And`, `!Or`, and `!Split` have no validation either.

**BUG-R7: `rawKeyText` returns empty string for non-scalar keys (line 784)**

```haskell
rawKeyText _ = ""
```

If a mapping key is a sequence, number, bool, or null, `rawKeyText` returns `""`. This means all non-string-like keys collapse to the empty string in `astToValueRaw`, causing silent data corruption where distinct keys map to `""` and overwrite each other.

### 1.2 Non-idiomatic Haskell

**NI-R1: `maybe "id"` instead of `fromMaybe` (line 240, 801)**

```haskell
-- Line 240
(maybe "<template>" id (tcInputUri parentCtx))

-- Line 801
fromMaybeVar = maybe "item" id
```

Both should use `fromMaybe`:

```haskell
fromMaybe "<template>" (tcInputUri parentCtx)
fromMaybeVar = fromMaybe "item"
```

**NI-R2: Duplicated `resolvePair` and `isSpecialKey` (lines 98-103, 127-132, 203-208)**

The `resolvePair` and `isSpecialKey` helper functions are defined identically three times across `resolveMapping`, `resolveMappingWithExpansion`, and `resolveResourcesMapping`. This should be extracted to a top-level helper.

**NI-R3: `lookupO k kvs == Nothing` instead of `isNothing` (line 478)**

```haskell
missing = filter (\k -> lookupO k kvs == Nothing) keys
```

Should use `isNothing . lookupO k kvs` or `not . isJust`.

**NI-R4: List appending in folds with `++` (lines 151-165, 210-217)**

```haskell
pure (acc ++ erResources expansionResult, mergedGlobals)
-- and
pure (acc ++ [(resName, resVal)], globals)
```

Repeated `acc ++ [item]` in a `foldM` is O(n^2). Should use a `DList` or reverse at the end.

### 1.3 Code Smells

**CS-R1: `deduplicateResources` defined twice (lines 170-181, 219-228)**

Nearly identical implementations of `deduplicateResources` and `deduplicateResources'`. Should be one shared function.

**CS-R2: `resolveMapItems` is a large shared function that's hard to follow (lines 515-535)**

The flow from `resolveMap` -> `resolveMapItems` is fine, but `resolveMapItems` is also used by `resolveConcatMap`, `resolveMergeMap`, `resolveMapListToHash`, making it a hidden coupling point. The `filterExpr` parameter being `Maybe YamlAst` adds optional complexity. Consider whether a HOF pattern (pass in the post-processing step) would be cleaner.

**CS-R3: `cfnTagParts` is mechanical boilerplate (lines 357-378)**

22 lines of mechanical case-matching could be replaced with a typeclass or a record on the tag type. Not a defect, but notable for maintainability — every new CFN tag requires updating this function, `validateCfnTag`, and `isCfnValidationMessage`.

### 1.4 Testing Gaps

**TG-R1: Zero unit tests for the resolver**

There are no test files that directly import or test `resolveAst`, `resolveMapping`, or any individual tag resolver. All resolver testing is indirect, through the `FixtureTest` module which exercises the full `preprocessYaml` pipeline. This means:

- Individual tag resolvers (e.g., `resolveGroupBy`, `resolveMapListToHash`, `resolveExpand`) have no isolated tests
- Edge cases in bracket expansion, dot-path traversal, and template variable pre-validation are untested in isolation
- Error messages from individual resolvers are never directly asserted

**TG-R2: `resolveExpand` has no fixture tests**

There are no test fixtures for `!$expand` in the fixture directories (no `expand-*.yaml` inputs).

**TG-R3: Custom resource expansion paths inadequately tested**

The `resolveMappingWithExpansion` and `resolveResourcesMapping` paths have complex logic (global section merging, deduplication, parent resource name collection) that is only tested through a few custom resource template fixtures.

### 1.5 Performance Concerns

**PC-R1: O(n^2) list operations throughout**

- `lookupO` is O(n) per call, used in inner loops (e.g., `resolveGroupBy` line 665, `mergeOObjects` line 548)
- `insertO` is O(n) per call
- `map fst base` in `mergeOObjects` (line 553) is O(n), called per overlay key
- `k `notElem` existingKeys` in `resolveMappingWithExpansion` (line 124) is O(n) per check
- `acc ++ [item]` pattern in folds is O(n^2)

For small YAML documents this is fine. For large CloudFormation templates (1000+ resources), these compound into measurable overhead. The OValue design (association lists) inherently limits performance.

**PC-R2: `length` on lists (lines 330-348)**

Multiple uses of `length items /= 2` on lists, which forces full spine evaluation. Could use a helper like:

```haskell
hasLength :: Int -> [a] -> Bool
hasLength 0 []     = True
hasLength n (_:xs) | n > 0 = hasLength (n-1) xs
hasLength _ _      = False
```

### 1.6 Safety Issues

**SI-R1: Three uses of `!!` (lines 466, 633, 684)**

Already detailed in BUG-R1. All are guarded but fragile.

**SI-R2: `reads` for index parsing (line 465)**

```haskell
case reads (T.unpack seg) of
  [(i, "")] | i >= 0 && i < length arr -> ...
```

`reads` is from `Text.Read` and is safe (returns `[]` on failure), but `T.unpack` creates an unnecessary `String` allocation. `T.decimal` from `Data.Text.Read` would be more idiomatic and avoid the `String` intermediate.

---

## 2. Conversion.hs (904 lines)

### 2.1 Bugs and Correctness Issues

**BUG-C1: Partial functions `T.head` and `T.tail` (lines 624-625)**

```haskell
findUnquotedComma :: Text -> Maybe Int
findUnquotedComma = go 0 False
  where
    go _ _ t | T.null t = Nothing
    go i inQ t =
      let c = T.head t
          rest = T.tail t
```

Although guarded by `T.null t` in the first equation, GHC does not guarantee evaluation order between pattern match clauses with guards. More importantly, this is *exactly* the kind of partial function usage the project CLAUDE.md forbids. The function should use `T.uncons`:

```haskell
go i inQ t = case T.uncons t of
  Nothing -> Nothing
  Just (c, rest) -> ...
```

**BUG-C2: Multiple unguarded `!!` on `allLines` (lines 50, 70, 531, 559, 640, 664, 674, 712, 894)**

Many uses of `allLines !! (lineNum - 1)` where the bounds check and the indexing are in separate expressions, or where the check uses `length allLines` (O(n) each time):

```haskell
-- Line 531 (UNGUARDED)
let tagLine = allLines !! (tagLn - 1)
```

At line 531, `tagLn` comes from `findAnyTagOnLine` which does its own bounds check, but this is an implicit invariant. If `findAnyTagOnLine` ever returns a bogus line number, this crashes.

Lines 50, 70 are guarded by the immediately preceding conditional, which is fine.

**BUG-C3: `translateParseError` off-by-one risk (line 69-72)**

```haskell
let allLines = T.lines source
    nextLine = posLine pos + 1
    nextCol = if nextLine >= 1 && nextLine <= length allLines
              then T.length (allLines !! (nextLine - 1)) + 1
              else 0
in ("unexpected end of file", pos { posLine = nextLine, posColumn = nextCol })
```

If `posLine pos` already points to the last line, `nextLine` will exceed `length allLines`, and `nextCol` becomes 0. The returned position will have `posLine = lastLine + 1`, `posColumn = 0`, which may confuse display formatting. This is a boundary condition that should be handled explicitly.

**BUG-C4: `extractFound` always returns `"wrong type"` (line 810)**

```haskell
extractFound :: Text -> Text
extractFound _ = "wrong type"
```

This function ignores its input entirely and always returns `"wrong type"`. The legacy resolver message classification (lines 303-324) calls this function but the result is always the same constant. Either the function is dead code that should be removed, or it should actually extract the type from the message.

**BUG-C5: `findTagExampleForUnexpectedField` searches wrong line range (line 884)**

```haskell
case findTagOnSourceLine source (loc { srcLocLine = max 1 (lineNum - 3) }) of
```

This adjusts the location to search line `lineNum - 3`, but `findTagOnSourceLine` searches the line at `srcLocLine` of the passed location. So this only checks one specific line (3 lines before), not a range. Then the fallback `findTagInNearbyLines` searches `lineNum - 5` to `lineNum`. This means if the tag is exactly 4 lines before the error, it's checked twice, but if it's 1-2 lines before, it's only found by the fallback. The first call is essentially redundant and confusing.

### 2.2 Non-idiomatic Haskell

**NI-C1: String-based error classification (entire file)**

The entire `classifyMessage` function (lines 100-402) is a 300-line chain of `T.isPrefixOf`/`T.isSuffixOf`/`T.isInfixOf` pattern matches on error message strings. This is inherently brittle — any change to error message wording in the resolver will silently cause misclassification. The idiomatic Haskell approach would be to use structured error types (sum type with data) rather than parsing strings.

However, this is understood to be a Rust compatibility requirement — the Rust version also classifies by string patterns. Still, the Haskell port could have enriched `ResolveError` with a structured error kind alongside the message, making the classification reliable while preserving the message for display.

**NI-C2: Redundant `T.length "constant"` calls (lines 148, 151, 196, 288, etc.)**

```haskell
T.drop (T.length "Variable not found: ") msg
T.drop (T.length "property '") msg
```

These compute `T.length` of string literals at runtime. Should use constants or `T.stripPrefix`:

```haskell
case T.stripPrefix "Variable not found: " msg of
  Just rest -> ...
```

**NI-C3: Guards with boolean conditions checking the same thing multiple ways**

The `classifyMessage` function uses overlapping and inconsistent prefix/infix/suffix checks. For example, line 304 checks `"!$map items must be" `T.isPrefixOf` msg` while line 286 already matched `"expected " `T.isPrefixOf` msg`. The ordering of guards matters and is fragile.

### 2.3 Code Smells

**CS-C1: 904-line file exceeds the project's 300-500 LOC guideline**

The project's CLAUDE.md says "Try to keep modules under ~300-500 LOC; split if larger and possible." At 904 lines, `Conversion.hs` is nearly double the upper bound. The file naturally splits into:
- Error classification (`classifyMessage` + helpers)
- Source position adjustment (`adjustLocationForTag` + helpers)
- String search utilities (`findSubstring`, `findAllSubstring`, etc.)
- Tag examples and CFN help text

**CS-C2: `tagExample` is a maintenance burden (lines 822-834)**

Every time a new tag is added, `tagExample` must be updated. It uses `T.toLower` for case-insensitive matching but the actual tag names in the codebase use camelCase (e.g., `!$mapListToHash`). A Map lookup would be cleaner.

**CS-C3: Repeated `"!$" `T.isPrefixOf` msg` / `findSubstring "!$"` patterns**

The string `"!$"` appears as a search target in at least 10 places. Should be a named constant.

**CS-C4: `isCfnValidationMessage` is a manual list (lines 837-849)**

Checking 11 CFN tags with individual `T.isPrefixOf` calls. Could use a list + `any`:

```haskell
isCfnValidationMessage msg = any (\prefix -> prefix `T.isPrefixOf` msg) cfnPrefixes
  where cfnPrefixes = ["!Ref ", "!Base64 ", ...]
```

### 2.4 Testing Gaps

**TG-C1: No unit tests for `classifyMessage`**

The 300-line classification function has zero unit tests. All testing is through the error fixture snapshot comparison script, which is an external bash script, not part of `cabal test`. Regressions in error classification would be caught only by the external script.

**TG-C2: No unit tests for position adjustment functions**

`adjustLocationForTag`, `adjustForTypeMismatch`, `findFieldColumn`, `findFlowColumn`, `findSecondBracketArg`, `findUnquotedComma` — none of these have direct unit tests.

**TG-C3: 11 error fixtures are skipped in `ErrorFixtureTest.hs` (lines 22-33)**

The error fixture test skips 11 out of ~49 fixture files, including critical ones like `variable-not-found`, `unknown-tag-typo`, `query-missing-key`, and `join-wrong-array-item-type`. These skipped tests mean error handling for these scenarios has no automated regression protection via `cabal test`.

### 2.5 Performance Concerns

**PC-C1: `T.lines source` called in every position adjustment function**

`adjustLocationForTag` (line 445), `adjustForTypeMismatch` (line 513), `findVariableColumn` (line 637), `findTagInLine` (line 661), `findAnyTagInLine` (line 671), `findTagOnSourceLine` (line 709), `findTagExampleForUnexpectedField` (line 881), `findTagInNearbyLines` (line 890) — each calls `T.lines source` independently. For a single error, `T.lines` may be called 3-5 times on the same source text. Should be computed once and threaded through.

**PC-C2: `length allLines` computed repeatedly (lines 49, 69, 558, 639, 663, 673, 711, 893)**

`length` on a list is O(n). Computing it at every bounds check is wasteful. Should be computed once alongside `allLines`.

**PC-C3: `findAllSubstring` allocates intermediate lists (line 690-697)**

The recursive search creates a list of all positions then only the first two are typically used (in `findSecondTag`). A specialized `findSecondOccurrence` would be more efficient.

### 2.6 Safety Issues

**SI-C1: `T.head` and `T.tail` — partial functions (lines 624-625)**

Already detailed in BUG-C1. These are explicitly forbidden by the project's CLAUDE.md.

**SI-C2: Multiple unguarded `!!` usages (line 531)**

Already detailed in BUG-C2. Most are guarded but line 531 relies on an implicit invariant.

---

## 3. Display.hs (261 lines)

### 3.1 Bugs and Correctness Issues

**BUG-D1: `getSourceLine` uses `!!` with guard (line 205)**

```haskell
getSourceLine lns n
  | n >= 1 && n <= length lns = Just (lns !! (n - 1))
  | otherwise = Nothing
```

Guarded, so safe, but `length lns` is O(n) on every call. This function is called 3 times per error display (prev, curr, next line), so `length` is computed 3 times.

**BUG-D2: `formatSourceContext` caret suppression condition (lines 149-151)**

```haskell
showCarets = case currLine of
  Just l  -> col > 0 && col <= T.length l
  Nothing -> False
```

If `col` equals `T.length l + 1` (one past end of line), carets are suppressed. This is likely intentional for "end of line" errors, but there's no comment explaining this design decision. For a position pointing at the newline character, carets should arguably still be shown.

**BUG-D3: `formatError` for `YamlSyntaxError` has an extra leading `"\n"` before the footer (line 94)**

```haskell
YamlSyntaxError info ->
    ...
    <> "\n" <> formatFooter c (ysiErrorId info)
```

This `"\n"` is unique to `YamlSyntaxError` — other error variants don't add it. This may cause inconsistent spacing in the output. Whether this matches the Rust output depends on the specific case.

### 3.2 Non-idiomatic Haskell

**NI-D1: `formatSourceContext` and `formatSourceContextNoCarets` share 90% of their logic**

Lines 140-173 and 177-194 are nearly identical. The difference is solely whether the caret line is emitted. Could be refactored to a single function with a `Bool` parameter or an `emitCarets :: Maybe (Int, Text)` parameter.

### 3.3 Code Smells

**CS-D1: Magic number `4` in `padGutter4` (line 197-201)**

The gutter width is hardcoded to 4 characters. For files with 10,000+ lines, line numbers exceed 4 digits, causing misalignment. Should either be dynamic based on the maximum line number, or documented as a fixed-width design decision (matching Rust).

**CS-D2: `TagParsingInfo` `tpiCaretColumn` field is never used in Display.hs**

The `tpiCaretColumn` field is defined in Enhanced.hs (line 57) and always set to 0 in Conversion.hs, and never read in Display.hs. This is dead data.

### 3.4 Testing Gaps

**TG-D1: `ErrorColorTest.hs` tests presence of ANSI codes but not output structure**

The 7 tests in `ErrorColorTest.hs` verify that ANSI codes are present/absent, but don't verify:
- Correct source context line content
- Correct caret positioning
- Correct line number formatting
- Multi-line error formatting
- Edge cases (line 0, column 0, empty source, source with single line)

**TG-D2: No tests for `formatSourceContextNoCarets`**

This code path (used for tag errors without caret info) has no tests.

**TG-D3: No tests for `padGutter4` edge cases**

No tests for negative line numbers, 0, or large line numbers (>9999).

### 3.5 Performance Concerns

**PC-D1: `T.lines source` called for every `formatSourceContext` invocation**

Same as PC-C1 — the source is re-split on every call.

### 3.6 Safety Issues

**SI-D1: `getSourceLine` uses `!!` (line 205)**

Guarded, but noted for completeness.

---

## 4. Ids.hs (184 lines)

### 4.1 Bugs and Correctness Issues

**BUG-I1: `errorIdCode` and `errorIdFromCode` can drift out of sync**

These are two independent case expressions mapping in opposite directions. If a new error ID is added to one but not the other, there's no compile-time check. This should use a bidirectional mapping (e.g., a single list of `(ErrorId, Int)` pairs with derived functions), or at minimum use a property test to verify round-tripping.

### 4.2 Non-idiomatic Haskell

**NI-I1: Missing `Enum`/`Bounded` instances**

`ErrorId` has `Enum`-like structure (each variant maps to a unique integer) but doesn't derive `Enum` or `Bounded`. This would enable `[minBound..maxBound]` for exhaustiveness checks and property tests.

**NI-I2: `showErrorId` uses string concatenation instead of `T.pack . show`**

```haskell
showErrorId eid = "ERR_" <> T.pack (show (errorIdCode eid))
```

This is fine but could pre-compute the map for all error IDs since the set is fixed.

### 4.3 Code Smells

No significant code smells. The file is clean and well-structured.

### 4.4 Testing Gaps

**TG-I1: No tests for `errorIdCode` / `errorIdFromCode` round-trip**

A simple property test would catch drift:

```haskell
prop_roundtrip :: ErrorId -> Bool
prop_roundtrip eid = errorIdFromCode (errorIdCode eid) == Just eid
```

**TG-I2: No test that all codes are unique**

Two error IDs could accidentally share the same code.

### 4.5 Performance Concerns

No concerns — all functions are simple case matches.

### 4.6 Safety Issues

No safety issues.

---

## 5. Cross-Cutting Concerns

### 5.1 Architecture: Stringly-Typed Error Classification

The most significant architectural concern across these files is the string-based error classification pipeline:

1. `Resolver.hs` creates `ResolveError` with a `Text` message
2. `Conversion.hs` parses that `Text` back into a structured `EnhancedPreprocessingError`
3. `Display.hs` formats the `EnhancedPreprocessingError`

This is essentially serialization-then-deserialization of error information through untyped strings. Changes to error messages in the resolver silently break classification in the conversion layer. The Haskell type system could eliminate this entire class of bugs by having the resolver emit structured error types directly.

### 5.2 Incomplete CFN Tag Coverage

CFN tag validation covers: `!Ref`, `!Base64`, `!GetAZs`, `!ImportValue`, `!Join`, `!Select`, `!FindInMap`, `!If`, `!Equals`, `!Not`.

Missing validation: `!Sub`, `!GetAtt`, `!Split`, `!Cidr`, `!Length`, `!ToJsonString`, `!Transform`, `!ForEach`, `!And`, `!Or`.

Similarly, `isCfnValidationMessage` in Conversion.hs only checks 11 prefixes but there are 19 CFN tags.

### 5.3 Error Fixture Tests Are Weak

The `ErrorFixtureTest.hs` only asserts that parsing + preprocessing produces *some* error — it doesn't assert the error type, message content, or position. Combined with 11 skipped fixtures, this means error handling has minimal regression protection via `cabal test`.

The external `error-snapshot-compare.sh` script provides stronger validation against Rust snapshots, but it's not integrated into `cabal test` and won't catch regressions in CI.

### 5.4 OValue Association List Design

The `OValue` design uses `[(Text, OValue)]` for objects (association lists), which preserves insertion order but makes every lookup O(n). This ripples through the resolver where `lookupO`, `insertO`, `mergeOObjects`, and key deduplication all operate on lists. For large CloudFormation templates (hundreds of resources, parameters, outputs), these operations compound.

This is an intentional design decision (key order preservation), but it's worth noting that `Data.Map.Strict` with a separate ordering vector, or `HashMap` with insertion-order tracking, would provide O(log n) or O(1) lookups while preserving order.

---

## 6. Summary of Findings

| Category                | Critical | Major | Minor | Info |
|:------------------------|:--------:|:-----:|:-----:|:----:|
| Bugs/Correctness        |     1    |   5   |   6   |   1  |
| Non-idiomatic Haskell   |     0    |   2   |   6   |   0  |
| Code Smells             |     0    |   2   |   7   |   0  |
| Testing Gaps            |     2    |   4   |   5   |   0  |
| Performance Concerns    |     0    |   2   |   5   |   0  |
| Safety Issues           |     1    |   1   |   3   |   0  |

**Critical issues:**
- BUG-C1: `T.head`/`T.tail` partial functions in `findUnquotedComma` (violates CLAUDE.md)
- TG-R1/TG-C1: Zero unit tests for the resolver and error classifier — the two most complex modules in the YAML engine

**Major issues:**
- BUG-R2: `resolveGroupBy` ignores `_templateAst` (potential functional gap)
- BUG-R3: `resolveResourcesMapping` drops global sections
- BUG-R4: `expandBrackets` infinite loop potential
- BUG-C4: `extractFound` always returns `"wrong type"`
- SI-R1: Three uses of `!!` on lists

---

## 7. Overall Grade: 62/100

**Justification:**

The code successfully ports a complex Rust YAML preprocessing engine to Haskell and achieves functional correctness for the main paths (49/49 error snapshots match Rust, 37/37 render snapshots pass). The type structure is reasonable, the Enhanced error type hierarchy is well-designed, and the Display module is clean and concise.

However, several factors pull the grade down significantly:

1. **Partial function usage** (T.head, T.tail, !!) directly violates the project's own coding standards. These aren't accidental — they appear in carefully written code, suggesting insufficient attention to the safety rules.

2. **String-based error classification** is an architectural weakness. While inherited from the Rust design, the Haskell port had the opportunity to use the type system to eliminate an entire class of fragile string-parsing bugs. This was a missed opportunity.

3. **Testing is critically weak** for these modules. The resolver — the core recursive evaluation engine — has zero isolated unit tests. The error classifier — a 300-line string-pattern matcher — has zero unit tests. All testing is integration-level, which provides coverage but not precision. When things break, there's no targeted test to tell you *what* broke.

4. **Code duplication** (`resolvePair`, `isSpecialKey`, `deduplicateResources` appear multiple times) and **file size violations** (Conversion.hs at 904 lines) indicate rushed implementation.

5. **Performance anti-patterns** (repeated `T.lines`, `length` on lists, `acc ++ [x]` in folds) are not critical for typical use but indicate insufficient consideration of algorithmic complexity.

The code works — and that matters. But it's carrying technical debt that will make it harder to maintain, extend, and debug.
