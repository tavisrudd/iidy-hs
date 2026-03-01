# Code Review 3b: CFN Operations & Polling Engine

**Date**: 2026-03-01
**Round**: 2 of 2
**Scope**: 12 production files, 8 test files (20 total)
**Prior reviews**: notes/2026-02-28-review-3-cfn-operations-polling.md

### Production Files
| File                                                            | Lines | Role                                     |
|:----------------------------------------------------------------|------:|:-----------------------------------------|
| `src/Iidy/Cfn/Operations/ConvertStack.hs`                      |   535 | convert-stack with embedded YAML emitter  |
| `src/Iidy/Cfn/StackOperations.hs`                              |   294 | Polling backbone, stack info, events      |
| `src/Iidy/Cfn/Operations/CreateStack.hs`                       |   115 | create-stack operation                    |
| `src/Iidy/Cfn/Operations/UpdateStack.hs`                       |   227 | update-stack (direct + changeset)         |
| `src/Iidy/Cfn/Operations/DeleteStack.hs`                       |   130 | delete-stack with confirmation            |
| `src/Iidy/Cfn/Operations/Changeset.hs`                         |   446 | Changeset create/execute/describe         |
| `src/Iidy/Cfn/Operations/WatchStack.hs`                        |   122 | Event-tailing watcher                     |
| `src/Iidy/Cfn/Operations/CreateOrUpdate.hs`                    |   168 | Dispatch to create or update              |
| `src/Iidy/Cfn/Operations/DescribeStack.hs`                     |   213 | Stack/event description + conversion      |
| `src/Iidy/Cfn/Operations/DescribeStackDrift.hs`                |   187 | Drift detection with pagination           |
| `src/Iidy/Cfn/RequestBuilder.hs`                               |   194 | API request construction                  |
| `src/Iidy/Cfn/Context.hs`                                      |   115 | Operation context                         |

### Test Files
| File                                                            | Lines | Role                                     |
|:----------------------------------------------------------------|------:|:-----------------------------------------|
| `test/Test/ConvertStackTest.hs`                                 |   106 | ConvertStack tests                        |
| `test/Test/CfnYamlEmitterTest.hs`                              |   249 | YAML emitter tests (NEW)                  |
| `test/Test/WatchStackTest.hs`                                   |   188 | WatchStack + polling tests                |
| `test/Test/DeleteStackTest.hs`                                  |    31 | Delete confirmation tests                 |
| `test/Test/ChangesetTest.hs`                                    |   112 | Changeset conversion tests                |
| `test/Test/RequestBuilderTest.hs`                               |    76 | RequestBuilder mapping tests              |
| `test/Test/Phase14FixTest.hs`                                   |   181 | Phase 14 regression tests                 |
| `test/Test/IntegrationTest.hs`                                  |   239 | Output pipeline integration tests         |

**Total production code**: ~2,746 lines
**Total test code**: ~1,182 lines

---

## Grade: 82/100

## Summary

Significant improvements since the first review. The five highest-priority issues were all addressed: Number formatting now uses `Scientific.floatingOrInteger` (issue 1.3), the partial `(!!)` was replaced with `Vector`-based safe indexing (issue 1.1), `percentEncode` now UTF-8 encodes before percent-encoding bytes (issue 6.2), `pollChangesetCompletion` has a retry limit (issue 6.4), and a comprehensive 249-line `CfnYamlEmitterTest` module was added (issue 4.1). The policy JSON pretty-printing (issue 1.9) was also fixed using `AesonPretty.encodePretty`, and the `sortCfnValue` DRY violation (issue 3.2) was resolved by routing through the shared `chooseWeightFn`.

The remaining issues are mostly structural -- duplicated terminal status lists, the `fromMaybe "unnamed-stack"` pattern appearing 10 times, `SomeException` catching in ConvertStack, and a subtle performance bug where `Set.fromList` is built but then queried with `notElem` (O(n) Foldable traversal) instead of `Set.notMember` (O(log n)). WatchStack also has a secondary `notElem` on a plain list that was not addressed. No new critical or high-severity bugs were found.

---

## Issues Fixed Since Last Review

| Issue ID | Description                                               | Status         | Notes                                                                                |
|:---------|:----------------------------------------------------------|:---------------|:-------------------------------------------------------------------------------------|
| 1.1      | Partial function `(!!)` in `generateDashedName`           | FIXED          | Now uses `V.Vector` with `V.!` and `V.length`; bounds still tight from `randomRIO`  |
| 1.2      | `sortCfnValue` rebuilds with `KM.fromList` (order lost)  | NOT FIXED      | Still uses `KM.fromList` on line 180; harmless because emitter re-sorts              |
| 1.3      | `Number n -> T.pack (show n)` produces Scientific repr    | FIXED          | Now uses `Scientific.floatingOrInteger` dispatch on line 286-288                     |
| 1.4      | Missing multiline string support in YAML emitter          | NOT FIXED      | Still no block scalar (`\|`) support; strings with `\n` emit as single-quoted        |
| 1.5      | Missing double-quote fallback in `quoteYamlString`        | NOT FIXED      | Single-quote doubling still the only strategy; functionally correct                  |
| 1.6      | `emitItem` inlines nested objects via `show`              | FIXED          | `emitItem` now pattern-matches nested Object/Array in first key (lines 255-263)      |
| 1.7      | `pollForCompletion` returns `""` on timeout               | NOT FIXED      | Still returns `""` as sentinel on lines 215 and 220                                  |
| 1.8      | `parameterizeEnv` order-dependent replacement             | NOT FIXED      | Same fold approach; very low risk                                                    |
| 1.9      | Policy JSON compact encoding instead of pretty            | FIXED          | Now uses `AesonPretty.encodePretty` on line 424                                     |
| 2.1      | Repeated `fromMaybe "unnamed-stack"` pattern              | NOT FIXED      | Still 10 occurrences across 5 files                                                  |
| 2.2      | `foldr (:) []` to convert Vector to list                  | FIXED          | No more `foldr (:) []` in ConvertStack; uses `V.null`, `V.toList`                   |
| 2.3      | Nested case-of staircase in `convertStackToIidy`          | NOT FIXED      | Still 4-level deep nesting on lines 387-406                                          |
| 2.4      | Duplicated `allTerminalStatuses` across 4 files           | NOT FIXED      | Still 5 separate definitions (Create, Update, Delete, Changeset, Watch)              |
| 2.5      | `maybe "" id` instead of `fromMaybe ""`                   | FIXED          | DeleteStack line 107 now uses `fromMaybe stackName mStackId`                         |
| 2.6      | `convertResource` always returns `Just`                   | FIXED          | Now returns `StackResourceInfo` directly (line 258); used with `map` not `mapMaybe`  |
| 2.7      | Mixed error-handling styles                               | NOT FIXED      | Still 4 different patterns across modules                                            |
| 3.1      | ConvertStack.hs 530+ lines with embedded emitter          | NOT FIXED      | Still one module; now 535 lines                                                      |
| 3.2      | `chooseWeightFn` duplicated in `sortCfnValue`             | FIXED          | `sortCfnValue` now calls `chooseWeightFn` (line 172)                                |
| 3.3      | SSM error silently swallowed                              | NOT FIXED      | Line 531: `_ <- try ... :: IO (Either SomeException ...)` still ignores errors       |
| 3.4      | Magic number for poll interval                            | NOT FIXED      | `* 1000000` still on line 191                                                        |
| 3.5      | `buildStackArgsYaml` YAML via string concatenation        | NOT FIXED      | Values still unescaped in generated YAML                                             |
| 3.6      | Excessive `fromMaybe ""` throughout                       | NOT FIXED      | Structural pattern; low risk but still present                                       |
| 4.1      | No tests for YAML emitter                                 | FIXED          | New `CfnYamlEmitterTest` module: 249 lines, covers numbers, bools, null, strings,   |
|          |                                                           |                | empty collections, nested objects, arrays, objects-in-arrays, round-trips            |
| 4.2      | No tests for full `convertStackToIidy` workflow           | NOT FIXED      | Still no DI boundary for mocking AWS calls                                           |
| 4.3      | No tests for `pollChangesetCompletion`                    | NOT FIXED      | Retry limit added but no test exercises it                                           |
| 4.4      | No tests for `checkStackState` / `findPendingChangeset`   | NOT FIXED      | Still untested AWS-interacting logic                                                 |
| 4.5      | No tests for `buildChangeSetCreationResult`               | NOT FIXED      | Pure function, still zero tests                                                      |
| 4.6      | No tests for `percentEncode`                              | NOT FIXED      | Function was rewritten for correctness but no unit tests added                       |
| 4.7      | No tests for `extractRegionFromArn`                       | NOT FIXED      | Still no test coverage                                                               |
| 4.8      | Polling timeout behavior untested                         | NOT FIXED      | Timeout, inactivity, callback interactions still untested                            |
| 4.9      | `DeleteStackTest` only tests `isConfirmation`             | NOT FIXED      | Still 31 lines, only confirmation tests                                              |
| 4.10     | No tests for `convertOutput`, `convertChangeSetSummary`   | NOT FIXED      | Still untested                                                                       |
| 4.11     | No tests for `buildConsoleUrl`                            | NOT FIXED      | Still untested                                                                       |
| 5.1      | O(n*m) event filtering in polling loop                    | PARTIALLY FIXED | Builds `Set.fromList` (line 196) but then uses `notElem` which is O(n) Foldable     |
| 5.2      | Triple Vector-to-list in array guards                     | FIXED          | Now uses `V.null` and `KM.null` directly                                             |
| 5.3      | `T.concat` with `map` instead of `Builder`                | NOT FIXED      | Still uses `T.concat $ map ...`; low priority                                        |
| 5.4      | `calculateEventDurations` triple traversal                | NOT FIXED      | Same approach; clear and correct                                                     |
| 6.1      | `(!!)` partial function                                   | FIXED          | (same as 1.1)                                                                        |
| 6.2      | `percentEncode` assumes ASCII                             | FIXED          | Now UTF-8 encodes via `TE.encodeUtf8` then percent-encodes bytes (lines 373-383)    |
| 6.3      | Unchecked `SomeException` catch in ConvertStack           | NOT FIXED      | Lines 388, 399, 419, 531 still catch `SomeException`                                |
| 6.4      | `pollChangesetCompletion` retries forever on errors       | FIXED          | Now has `maxRetries = 30` (60 seconds), returns FAILED info on exhaustion            |
| 6.5      | `hPutStrLn stderr` in ConvertStack                        | NOT FIXED      | 6 occurrences still bypass output pipeline                                           |
| 7.1      | No pagination for `DescribeStackEvents`                   | NOT FIXED      | Still single-page fetch                                                              |
| 7.2      | No pagination for `ListChangeSets`                        | NOT FIXED      | Still single-page fetch                                                              |
| 7.5      | `GetTemplate` missing explicit `templateStage`            | NOT FIXED      | Default is correct; being explicit would document intent                             |
| 7.6      | Missing error handling in `createStack`/`updateStack`     | NOT FIXED      | `createStack` still calls `Amazonka.send` without try/catch                          |
| 8.5      | `buildChangeSetCreationResult` always includes nextSteps  | NOT FIXED      | Still unconditional                                                                  |

**Summary**: 13 of 38 tracked issues FIXED, 1 PARTIALLY FIXED, 24 NOT FIXED.

---

## New Issues Found

### N1: `notElem` on `Set` is O(n), not O(log n) (Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs:197`
**What**: The fix for issue 5.1 builds a `Set` via `Set.fromList lastEventIds` (line 196) but then calls `notElem` (line 197), which dispatches through the `Foldable` instance of `Set` -- that traverses elements sequentially in O(n), not using the tree structure. The original review asked for `Set` membership; the fix is 90% there but misses the final step.
**Fix**: Replace `e.eventId \`notElem\` lastEventSet` with `not (Set.member e.eventId lastEventSet)` or `Set.notMember e.eventId lastEventSet`.

### N2: WatchStack `seenIds` is still a plain list with `notElem` (Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/WatchStack.hs:83,91`
**What**: `seenIds` is built as `map (.eventId) initialEvents` (a `[Text]` list) and then queried via `notElem` on every callback invocation. This is O(n) per event per callback. For long-running stacks with many initial events, this accumulates.
**Fix**: Build `seenIds` as `Set.fromList (map (.eventId) initialEvents)` and use `Set.notMember`.

### N3: `generateDashedName` still uses partial `V.!` operator (Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:433`
**What**: Issue 1.1 was marked fixed by switching from list `(!!)` to `V.!`, but `V.!` is also a partial function -- it throws an exception on out-of-bounds. The coding standard says "No partial functions (head, tail, fromJust, etc.)". While the bounds are tight from `randomRIO`, the letter of the standard is not satisfied.
**Fix**: Use `V.unsafeIndex` (same performance, acknowledges unchecked access) or `V.!?` with a fallback. Given the tight bounds, `V.!` is defensible in practice -- this is a pedantic note.

### N4: `buildStackArgsYaml` does not escape YAML special chars in parameter values (Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:363`
**What**: `formatParam` on line 363 emits `"  " <> k <> ": " <> v` where `v` is the raw parameter value from AWS. If `v` contains YAML special characters (e.g., `: `, `#`, `{`, leading `*`), the generated `stack-args.yaml` will be invalid YAML. Similarly, `formatTag` on line 367 has the same issue.
**Fix**: Apply `quoteYamlString` to the value: `"  " <> k <> ": " <> quoteYamlString v`.

### N5: `pollForCompletion` constructs `Set.fromList` on every poll iteration (Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs:196,241`
**What**: On every poll cycle, `Set.fromList lastEventIds` is constructed from the full event ID list, then discarded. The next iteration passes `map (.eventId) events` (line 241) which is again a plain list. The Set is reconstructed every 2 seconds. It would be more efficient to thread a `Set Text` through the loop directly.
**Fix**: Change the `go` function signature to take `Set Text` instead of `[Text]`, and update with `Set.fromList (map (.eventId) events)` once per iteration at the end.

### N6: `deleteStack` calls `getStackId` after confirmation, causing an extra API call (Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DeleteStack.hs:106`
**What**: The stack is already fetched on line 74 (`getStack ctx stackName`), which returns a `CF.Stack` that contains `.stackId`. Then on line 106, `getStackId` makes another `DescribeStacks` API call to get the same information. This is a redundant API call.
**Fix**: Extract `stackId` from the already-fetched `cfnStack` on line 87: `let pollTarget = fromMaybe stackName cfnStack.stackId`.

### N7: `convertDetail` always returns `Just` (Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:311-320`
**What**: `convertDetail` has return type `Maybe ChangeDetail` but always returns `Just`. It is called via `mapMaybe convertDetail ...` on line 306. This is the same pattern that was fixed for `convertResource` (issue 2.6) -- the `Maybe` wrapper is semantically misleading.
**Fix**: Change return type to `ChangeDetail` and use `map` instead of `mapMaybe`.

### N8: `deleteStack` exit code 130 on cancellation differs from `updateStackWithChangeset` (Info)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DeleteStack.hs:103`, `UpdateStack.hs:210`
**What**: Both return `Right 130` on user cancellation, but `deleteStack` returns `Right 0` (success) when the stack is absent. Meanwhile `confirmChangesetExecution` in the changeset path uses `requestConfirmation` from the shared `Iidy.Confirm` module. The cancellation behavior is consistent across operations, which is good. No action needed -- just noting the observation.

---

## Remaining Unfixed Issues

The following issues from the prior round remain unfixed. They are ordered by descending severity/impact:

**Medium severity** (should fix before release):
1. **2.4**: Duplicated `allTerminalStatuses` across 5 files -- risk of silent divergence
2. **6.3**: `SomeException` catching in ConvertStack (4 occurrences) -- catches async exceptions
3. **3.5**: `buildStackArgsYaml` values not YAML-escaped (see also N4 above)
4. **2.7**: Mixed error-handling styles across modules
5. **7.1/7.2**: No pagination for `DescribeStackEvents` and `ListChangeSets`
6. **1.4**: No multiline string support in YAML emitter
7. **6.5**: `hPutStrLn stderr` in ConvertStack bypasses output pipeline

**Low severity** (cleanup when convenient):
8. **1.2**: `sortCfnValue` builds into unordered `KM.fromList` (harmless -- emitter re-sorts)
9. **1.7**: `pollForCompletion` returns `""` on timeout instead of `Maybe` / ADT
10. **2.1**: `fromMaybe "unnamed-stack"` repeated 10 times
11. **2.3**: Nested case staircase in `convertStackToIidy`
12. **3.1**: ConvertStack at 535 lines (emitter should be separate module)
13. **3.3**: SSM PutParameter errors silently swallowed
14. **3.4**: Magic number `1000000` for microsecond conversion
15. **5.3**: `T.concat $ map` instead of Builder
16. **8.5**: `buildChangeSetCreationResult` always includes nextSteps

**Testing gaps** (should address for confidence):
17. **4.3**: `pollChangesetCompletion` retry limit untested
18. **4.5**: `buildChangeSetCreationResult` untested
19. **4.6**: `percentEncode` untested (now correct but no regression guard)
20. **4.7**: `extractRegionFromArn` untested
21. **4.8**: Polling timeout behaviors untested
22. **4.10**: `convertOutput`, `convertChangeSetSummary` untested
23. **4.11**: `buildConsoleUrl` untested

---

## Test Coverage Assessment

### Well-tested areas
- **YAML emitter** (NEW): 249 lines covering `inlineValue`, `quoteYamlString`, `emitCfnYaml` for scalars, nested objects, arrays, objects-in-arrays, empty collections, and round-trip tests. This was the biggest testing gap in the prior review and is now solidly covered.
- **Polling engine**: 8 tests via `pollForCompletionWith` DI boundary. Covers terminal detection, multi-poll, new-event-only filtering, resource vs stack event distinction, DELETE_COMPLETE, UPDATE_ROLLBACK_COMPLETE.
- **Changeset conversions**: `convertChange` (5 tests), `convertDetail` (2 tests), `generateDashedName` (3 tests).
- **RequestBuilder**: 20 tests covering all mapping functions.
- **Integration tests**: Full OutputData sequence tests for create, describe, delete, changeset, drift, absent, and lint flows. All 26 OutputData variants exercised through both Interactive and JSON renderers.
- **Phase 14 regressions**: Event duration minimum, CLI arguments, tag validation, isNoUpdatesError, credential display -- all tested.

### Gaps remaining
- **Pure helper functions** without tests: `percentEncode`, `extractRegionFromArn`, `buildConsoleUrl`, `buildChangeSetCreationResult`, `convertOutput`, `convertChangeSetSummary`, `buildStackArgsYaml` with special characters in values.
- **Polling edge cases**: timeout, inactivity timeout, `pcWaitForStatusChange` interaction with inactivity, callback firing order under timeout.
- **`pollChangesetCompletion`**: Retry limit behavior untested -- the fix from issue 6.4 has no test exercising the `maxRetries` path.
- **Error paths**: No tests for how operations behave when `Amazonka.send` throws various error types.
- **ConvertStack AWS flow**: No DI boundary exists; `convertStackToIidy` and `processStack` are untestable without real AWS credentials.

### Test-to-code ratio
- Production code in scope: ~2,746 lines
- Test code in scope: ~1,182 lines
- Ratio: 0.43 (tests per production line)
- This is reasonable for a CLI tool with significant AWS interaction code. The pure functions have good coverage; the IO-heavy code is inherently harder to test.

---

## Positive Observations

1. **Number formatting fix is thorough**: The `Scientific.floatingOrInteger` approach on lines 286-288 correctly distinguishes integers from floats. The test suite validates `1.0e2` renders as `100`, which catches the exact bug from the prior review.

2. **percentEncode rewrite is correct**: The new implementation (lines 373-383) UTF-8 encodes via `TE.encodeUtf8` then processes raw bytes, correctly handling multi-byte Unicode code points. The `isUnreserved` check operates on `Word8` values with the correct RFC 3986 ranges.

3. **pollChangesetCompletion retry limit is well-designed**: The error count resets on success (line 168: `go 0`), meaning transient errors don't accumulate across successful polls. Only consecutive failures trigger the limit. The failure info includes a descriptive reason.

4. **CfnYamlEmitterTest is comprehensive**: 249 lines with 7 test groups covering all inline value types, string quoting edge cases, emission of scalars/nested/arrays/objects-in-arrays, and round-trip parsing. Good use of the `numFrom` helper to construct exact Scientific values.

5. **emitItem handles nested first-key correctly**: The fix for issue 1.6 properly pattern-matches `Object`/`Array` in the first key-value pair of an array element (lines 255-263), emitting block-style YAML instead of falling through to `inlineValue`'s `show` fallback.

6. **Policy pretty-printing uses proper library**: `AesonPretty.encodePretty` (line 424) produces human-readable JSON matching the Rust `serde_json::to_string_pretty` behavior.

7. **Clean separation of pure and IO persists**: All conversion functions (`convertEvent`, `convertStack`, `convertChange`, `convertDetail`, `buildEventsDisplay`, `calculateEventDurations`) remain pure and testable.

---

## Grade Justification

**Starting at 100, deductions:**

| Deduction | Reason                                                                                     |
|----------:|:-------------------------------------------------------------------------------------------|
|        -3 | Duplicated `allTerminalStatuses` across 5 files (risk of silent divergence)                |
|        -2 | `SomeException` catching in ConvertStack (4 sites) catches async exceptions                |
|        -2 | `buildStackArgsYaml` values not YAML-escaped (N4)                                          |
|        -1 | `notElem` on `Set` is O(n) not O(log n) (N1) -- fix was incomplete                        |
|        -1 | WatchStack `seenIds` still plain list with `notElem` (N2)                                  |
|        -1 | `convertDetail` always returns `Just` with `mapMaybe` (N7)                                 |
|        -1 | Redundant `getStackId` API call in `deleteStack` (N6)                                      |
|        -1 | No pagination for `DescribeStackEvents` / `ListChangeSets`                                 |
|        -1 | No multiline string support in YAML emitter                                                |
|        -1 | `hPutStrLn stderr` bypasses output pipeline in ConvertStack                                |
|        -1 | `pollForCompletion` returns `""` sentinel instead of proper type                           |
|        -1 | `fromMaybe "unnamed-stack"` repeated 10 times                                             |
|        -1 | `pollChangesetCompletion` retry limit untested                                             |
|        -1 | Several pure helpers (`percentEncode`, `extractRegionFromArn`, `buildConsoleUrl`) untested  |

**Total deductions: -18**

**Final grade: 82/100**

The code is materially improved from 72/100. All critical and high-severity bugs are resolved. The remaining issues are structural debt (duplication, code organization), a handful of minor correctness concerns (YAML escaping in generated files, `SomeException` catching), and testing gaps for pure helper functions that should be straightforward to address.
