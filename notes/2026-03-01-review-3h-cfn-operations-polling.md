# Code Review R8: CFN Operations & Polling

**Date**: 2026-03-01
**Round**: 8
**Scope**: CFN operations, polling engine, YAML emitter, changeset operations
**Prior reviews**: none (independent review)
**Note**: Architectural items listed in known-deferred list are excluded from this review.

## Grade: 82/100

## Summary

The CFN operations layer is well-structured with clear separation of concerns: StackOperations provides the polling engine and shared utilities, individual operation modules (Create, Update, Delete, Watch, Describe, Changeset, Convert) each handle one command, and RequestBuilder cleanly maps domain types to AWS API types. The code is generally idiomatic Haskell with good use of qualified imports, explicit type signatures, and reasonable module sizes.

The main concerns are: (1) a YAML escape spec compliance bug in `quoteYamlString`, (2) an incorrect total count in `buildEventsDisplay` that happens to be masked by a guard, (3) several pure exported functions with no test coverage, and (4) some minor structural issues around code duplication in error-checking patterns.

## Issues Found

### OPS-01: `escapeForDoubleQuote` produces non-compliant YAML `\x` escapes (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:299`
**What**: The `escapeForDoubleQuote` function uses `showHex (fromEnum c) ""` to emit `\x` escape sequences for control characters below U+0020 (excluding `\n`, `\r`, `\t`). Haskell's `showHex` does not zero-pad, so a character like U+0001 is emitted as `\x1` instead of `\x01`. The YAML 1.1 and 1.2 specifications require exactly two hex digits for `\xNN` escape sequences. Some YAML parsers will reject or misparse `\x1`.
**Fix**: Zero-pad the hex output to always be 2 digits:
```haskell
_ | c < ' '   -> "\\x" <> T.pack (padHex (fromEnum c))
-- where
padHex n = let h = showHex n "" in replicate (2 - length h) '0' ++ h
```

### OPS-02: `buildEventsDisplay` computes incorrect `total` when input is shorter than `numEvents` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs:133`
**What**: `total = numEvents + length rest`. When the input list has fewer than `numEvents` elements, `rest` is `[]` and `total = numEvents + 0 = numEvents`, even though the actual total is `length events` (which is less). For example, with 5 events and `numEvents = 10`, `total` is 10 but the real total is 5. The bug is currently masked because the `truncInfo` guard (`total > numEvents`) prevents the incorrect value from being used. However, this is fragile -- if `total` is ever used elsewhere or the guard changes, it would produce wrong truncation metadata.
**Fix**: `total = length events` (or equivalently `length taken + length rest`).

### OPS-03: Terminal status lists use linear `elem` on `[Text]` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Context.hs:120-156` and callers in `StackOperations.hs:274`, `CreateStack.hs:78`, `UpdateStack.hs:115`
**What**: The terminal status lists (`allTerminalStatuses`, `createTerminalStatuses`, etc.) are plain `[Text]` and are searched with `elem`, giving O(n) per lookup. These lists have 13-15 elements and are called once per poll cycle (every 2 seconds), so the actual performance impact is negligible. However, using `Set.fromList` would be more idiomatic for membership tests and would prevent the list from growing into a performance concern if more statuses are added.
**Fix**: Change to `Set Text` and use `Set.member`. Low priority since the current performance is fine.

### OPS-04: `nextSteps` in `buildChangeSetCreationResult` always shows CREATE instructions (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:309-313`
**What**: The `nextSteps` text says "Your new stack is now in REVIEW_IN_PROGRESS state. To create the resources run the following" regardless of whether the changeset is CREATE or UPDATE type. For UPDATE changesets on existing stacks, this message is misleading -- the stack already exists and isn't "new", nor is it in REVIEW_IN_PROGRESS.
**Fix**: Conditionally adjust the message based on `stackExists`:
```haskell
nextSteps = if stackExists
  then ["To apply the update, execute the changeset:", ...]
  else ["Your new stack is now in REVIEW_IN_PROGRESS state...", ...]
```

### OPS-05: `watchStack` catches `PollInactivityTimeout` but continues to collect stack contents (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/WatchStack.hs:82-87`
**What**: When polling returns `PollInactivityTimeout` (matched by the wildcard `_` on line 84), `watchStack` falls through to collect stack contents and return `Right 0`. This is likely intentional (inactivity timeout means no new events, so collect final state and exit), but the exit code is 0 (success) even when the operation timed out. The Rust implementation may differ here -- returning 0 implies the watch completed normally when it actually timed out.
**Fix**: Consider returning a distinct exit code for inactivity timeout (e.g., `Right 2`) to allow callers to distinguish timeout from normal completion. Or document that 0-on-timeout is intentional.

### OPS-06: `findPendingChangeset` does not paginate (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:371-381`
**What**: `findPendingChangeset` uses a single `Amazonka.send` call rather than `Amazonka.paginate`. If a stack has more changesets than fit on one page (the default page size), the pending changeset might not be found. In `collectStackContents` (StackOperations.hs:138-142), the same ListChangeSets call properly uses pagination. A stack in REVIEW_IN_PROGRESS typically has only one pending changeset, so this is unlikely to be an issue in practice.
**Fix**: Use `Amazonka.paginate` to be consistent with `collectStackContents`.

### OPS-07: `quoteYamlString` does not quote strings starting with `!` (tag indicator) (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:302-311`
**What**: In YAML, `!` at the start of a scalar is a tag indicator (`!Ref`, `!GetAtt`, etc.). The `needsQuoting` check does include `!` in its character set (`":{}&*?|>!%@\`#,[]\""`), which would trigger on `!` anywhere in the string. On closer inspection this is actually correct -- `!` is in the `elem` check character set. No bug here. (Retracted.)

### OPS-08: `convertDescribeResponse` uses `resp.status` without `Maybe` wrapping (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:253`
**What**: `csiStatus = CF.fromChangeSetStatus resp.status` -- if `resp.status` is the raw field from the DescribeChangeSetResponse, this assumes it is always present. Looking at the amazonka API, `DescribeChangeSetResponse.status` is indeed a required field (not `Maybe`), so this is safe. (Retracted after verification.)

## Test Coverage Assessment

### Untested pure/testable functions:

1. **`convertResource`** (`StackOperations.hs:307-315`): Pure conversion from `CF.StackResource` to `StackResourceInfo`. No tests. This is a straightforward field mapping but could have regressions if the amazonka types change.

2. **`convertOutput`** (`StackOperations.hs:317-325`): Pure conversion from `CF.Output` to `StackOutputInfo`. Returns `Nothing` when `outputKey` is absent. No tests.

3. **`convertChangeSetSummary`** (`StackOperations.hs:327-342`): Pure conversion from `CF.ChangeSetSummary` to `ChangeSetInfo`. Returns `Nothing` when name or ID is absent. No tests.

4. **`convertStack`** (`DescribeStack.hs:87-123`): Pure conversion from `CF.Stack` to `StackDefinition`. Complex field mapping with tag/parameter extraction. No direct unit tests (only used indirectly).

5. **`buildEventsDisplay`** (`DescribeStack.hs:130-144`): Pure function building StackEventsDisplay from events. No tests. Should test truncation logic, edge cases with fewer events than numEvents, and empty input.

6. **`convertEventWithDuration`** (`DescribeStack.hs:196-202`): Tested in `Phase14FixTest.hs` but only for the sub-second rounding case. Not tested for: negative durations (event before start time), very large durations.

7. **`chooseWeightFn`** (`ConvertStack.hs:254-264`): Pure function selecting weight functions by parent/current key. No tests. All the weight functions (`cfnDocumentWeight`, `cfnParameterWeight`, etc.) are also untested individually.

8. **`sortObjectPairs`** (`ConvertStack.hs:164-171`): Pure function sorting an aeson KeyMap. Tested indirectly through `templateBodyToYaml` but no direct unit tests for edge cases (equal weights, empty map).

9. **`mapCapabilities` with all-invalid input** (`RequestBuilder.hs:156-160`): When all capabilities are invalid, `mapCapabilities (Just ["INVALID1", "INVALID2"])` returns `Nothing` (all filtered out). This edge case is not tested.

10. **`stackExists`** (`StackOperations.hs:89-94`): Tests `DELETE_COMPLETE` as non-existent, but requires AWS mocking so out of scope. The `isStackNotFoundError` helper IS well-tested.

### Well-tested functions:
- `formatEvent`, `stackNameFromId`, `isStackNotFoundError`, `isNoUpdatesError` -- good coverage in `WatchStackTest.hs`
- `pollForCompletionWith` -- excellent DI-based mock testing with 7 scenarios
- `calculateEventDurations` -- thorough with edge cases (sub-second, no timestamp, multiple resources)
- `convertChange`, `convertDetail`, `generateDashedName` -- good coverage
- `percentEncode`, `extractRegionFromArn`, `buildChangesetConsoleUrl`, `buildChangeSetCreationResult` -- thorough
- `parameterizeEnv`, `parameterizeStackName`, `templateBodyToYaml`, `buildStackArgsYaml` -- good coverage
- `inlineValue`, `quoteYamlString`, `emitCfnYaml` -- extensive with many edge cases
- `mapCapability`, `mapCapabilities`, `mapParameters`, `mapTags`, `mapOnFailure` -- good coverage
- `buildConsoleUrl` -- good coverage

## Positive Observations

1. **Excellent polling architecture**: The `pollForCompletionWith` dependency injection pattern is a textbook example of testable IO code. By accepting an `IO [StackEvent]` fetcher, the entire polling loop can be tested with mock data and zero-second poll intervals. This is well-designed.

2. **Clean module boundaries**: Each operation module (Create, Update, Delete, Watch, Describe, Changeset) has a single public entry point with a consistent signature pattern `(CfnContext -> ... -> (OutputData -> IO ()) -> IO (Either Text Int))`. This makes the code predictable and easy to navigate.

3. **Shared helpers extracted well**: `mkStandardPollConfig`, `emitStackDefinition`, `buildEventsDisplay`, and `convertStack` are properly shared through `DescribeStack.hs`, avoiding duplication across operation modules.

4. **Thorough YAML quoting**: The `quoteYamlString` function handles an impressive range of YAML edge cases: boolean-like strings, number-like strings, null aliases, dash-sequence indicators, dot-prefixed floats, single-quote prefixes, and control characters with double-quoting. The test coverage for this function is also excellent.

5. **Good use of amazonka qualified imports**: The `DuplicateRecordFields` issue is handled cleanly with qualified imports and explicit lens use where needed (e.g., `CCS.createChangeSetResponse_id`).

6. **RequestBuilder is clean and consistent**: All four request builders follow the same pattern: get token, load template, build base request, fill fields. Easy to audit.

7. **Output type safety**: The `OutputData` ADT with 25+ constructors provides strong typing for the entire output pipeline, preventing confusion between output types at compile time.

8. **convertStack is comprehensive**: All stack fields are mapped including capabilities, tags, parameters, notification ARNs, and derived fields like console URL and StackSet name.

## Grade Justification

Starting from 100:

| Deduction | Points | Reason                                                                    |
|-----------|--------|---------------------------------------------------------------------------|
| OPS-01    | -6     | YAML spec non-compliance in escape sequences (real but rare trigger)      |
| OPS-02    | -2     | Incorrect total count, masked by guard but fragile                        |
| OPS-03    | -1     | Linear search on status lists (negligible perf impact)                    |
| OPS-04    | -2     | Misleading next-steps text for UPDATE changesets                          |
| OPS-05    | -1     | Ambiguous exit code on inactivity timeout                                 |
| OPS-06    | -1     | Non-paginated changeset lookup (unlikely to hit in practice)              |
| Coverage  | -5     | Several pure conversion functions lack direct unit tests                  |

**Total: 82/100**

The codebase shows strong engineering discipline: consistent patterns, good separation of concerns, and excellent testability via dependency injection. The main gaps are in YAML edge-case correctness and test coverage for conversion functions. No critical bugs that would cause runtime failures under normal operation.
