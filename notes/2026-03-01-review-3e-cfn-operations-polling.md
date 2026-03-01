# Code Review R5: CFN Operations & Polling

**Date**: 2026-03-01
**Round**: 5
**Scope**: CFN operations, polling engine, YAML emitter, changeset operations
**Prior reviews**: none (independent review)

## Grade: 79/100

## Summary

The CFN operations layer is well-structured with clear separation of concerns: a shared `StackOperations` module provides building blocks (fetch, poll, collect), individual operation modules compose these into command-specific flows, and `RequestBuilder` handles AWS API request construction. The code is readable, has explicit type signatures everywhere, and avoids partial functions consistently. The polling engine design with `pollForCompletionWith` dependency injection is particularly good for testability.

However, there are several issues ranging from a correctness bug in the polling loop's event set growth to duplicated patterns, missing YAML quoting cases, and gaps in test coverage for the operation modules themselves (which are only tested through integration sequences rather than unit tests). The code is production-viable but would benefit from the fixes identified below.

## Issues Found

### OPS-01: Unbounded event set growth in polling loop (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:279-280
**What**: On every poll cycle, ALL event IDs (not just new ones) are accumulated into `lastEventSet` via `Set.union`. The set only grows and is never pruned. For long-running operations (multi-hour deployments with hundreds of resources), this set grows with every poll cycle even when events are repeated. The entire event list's IDs are re-inserted each cycle.
**Fix**: Only insert new event IDs, not all event IDs:
```haskell
-- Current (re-inserts all events every cycle):
go startTime lastEventTimeRef hasSeenNewEventsRef
   (Set.union lastEventSet (Set.fromList (map (.eventId) events)))

-- Better (only insert new IDs):
let newIds = Set.fromList (map (.eventId) newEvents)
in go startTime lastEventTimeRef hasSeenNewEventsRef
      (Set.union lastEventSet newIds)
```
Note: This is a performance issue, not a correctness bug. The `Set.union` of already-present elements is a no-op functionally, but it does allocate unnecessarily on each cycle.

### OPS-02: `allTerminalStatuses` re-exported from WatchStack creates shadowing ambiguity (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/WatchStack.hs`:9,20
**What**: `WatchStack` exports `allTerminalStatuses` which it imports from `Iidy.Cfn.Context`. This re-export means consumers who import both `WatchStack` and `Context` could get ambiguity. The re-export also obscures the canonical location of this value.
**Fix**: Remove `allTerminalStatuses` from the WatchStack export list. Consumers should import it from `Iidy.Cfn.Context` directly.

### OPS-03: `quoteYamlString` does not quote strings starting with special YAML indicators (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`:275-286
**What**: The `needsQuoting` function checks for various special characters and reserved words, but does not handle:
- Strings starting with `-` followed by a space (YAML block sequence indicator: `- value`)
- Strings that look like numbers (e.g., `"123"`, `"0.5"`, `"1e3"`) which YAML will parse as numeric
- Strings starting with `.` (potential YAML float prefix)
- The string `"~"` (YAML null alias)
- Strings starting with `'` (single-quote opens a flow scalar)

When used in `buildStackArgsYaml` to emit parameter/tag values fetched from CloudFormation, these values could produce invalid or misinterpreted YAML.
**Fix**: Extend `needsQuoting` to also check:
```haskell
|| T.isPrefixOf "- " t || t == "-"
|| T.isPrefixOf "." t
|| t == "~"
|| looksLikeNumber t
|| T.isPrefixOf "'" t
```

### OPS-04: `parameterizeEnv` has overlapping replacement issue (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`:69-71
**What**: `parameterizeEnv` uses `foldl` with `T.replace` over the list of known environments. If a string contains "testing" and "integration", both will be replaced. Worse, the list order matters: "production" is checked before others, so "production-testing" would first become "{{environment}}-testing" then NOT match "testing" within "{{environment}}-" (which is fine), but "testing-production" would become "testing-{{environment}}" then "{{environment}}-{{environment}}" because "testing" would match in a later pass. The fix in the second case is that `foldl` processes left-to-right: "production" first, then "staging", etc. So "testing-production" becomes "testing-{{environment}}" then "{{environment}}-{{environment}}". This double-replacement is a bug.
**Fix**: Use `T.breakOn` to find the first match and replace only that occurrence, or replace all occurrences only for the single best-matching environment (e.g., longest match). Alternatively, replace the first matching environment and stop.

### OPS-05: `extractRegionFromArn` falls back to "us-east-1" silently (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`:341-344
**What**: When the changeset ARN cannot be parsed (e.g., empty string or malformed), the region silently defaults to "us-east-1". This produces a plausible-looking but wrong console URL rather than signaling the error.
**Fix**: While the fallback is likely intentional for robustness (matching Rust behavior), consider returning `Maybe Text` and handling the error case in `buildChangeSetCreationResult`, or at minimum logging a warning.

### OPS-06: `createTerminalStatuses` and `updateTerminalStatuses` are identical (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Context.hs`:132-139
**What**: Both `createTerminalStatuses` and `updateTerminalStatuses` are defined as `allTerminalStatuses ++ ["DELETE_SKIPPED", "REVIEW_IN_PROGRESS"]`. This is dead duplication -- a reader might expect them to differ.
**Fix**: Either share a single definition (e.g., `writeTerminalStatuses`) or document why they are intentionally separate (for future divergence). As-is, it's confusing.

### OPS-07: `collectStackContents` fetches ALL exports across the account (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:142-159
**What**: `collectStackContents` calls `ListExports` which paginates through ALL exports in the AWS account (could be thousands), then filters client-side by stack ARN. The `ListExports` API has no server-side stack filter. For accounts with many exports, this is an unnecessarily expensive and slow operation on every describe/watch/create/update/delete completion.
**Fix**: This likely matches the Rust implementation (which also has no server-side filter available), but it should be documented as a known performance concern. Consider caching the exports or making this step optional for operations that don't display exports.

### OPS-08: Event set tracks `eventId` field that comes from `Maybe Text` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:235,280
**What**: The polling loop filters events by `e.eventId` which is a `Text` field in the amazonka `StackEvent` type. Looking at the usage, the code accesses `.eventId` directly. In amazonka 2.0, `StackEvent.eventId` is a required `Text` field (not `Maybe`), so this is safe. However, the `newStackEvent` constructor in tests shows `eventId` is a required parameter, confirming it's always present. No bug here, but worth noting.
**Fix**: No fix needed. Just confirming correctness.

### OPS-09: Duplicated "fetch stack + emit StackDefinition" pattern (Severity: Minor)
**File**: Multiple files
**What**: The pattern of fetching a stack and emitting `OdStackDefinition` is repeated identically in:
- `CreateStack.hs`:64-67
- `UpdateStack.hs`:109-112, 157-159
- `DeleteStack.hs`:73
- `WatchStack.hs`:56-58
- `Changeset.hs`:188-191
- `CreateOrUpdate.hs`:93-96, 149-152

Each occurrence follows the exact same structure:
```haskell
mStack <- getStack ctx stackId
case mStack of
  Just cfnStack -> emit (OdStackDefinition (convertStack cfnStack regionText) True)
  Nothing -> pure ()
```
**Fix**: Extract a helper function like:
```haskell
emitStackDefinition :: CfnContext -> Text -> (OutputData -> IO ()) -> IO ()
emitStackDefinition ctx stackId emit = do
  let regionText = Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))
  mStack <- getStack ctx stackId
  case mStack of
    Just cfnStack -> emit (OdStackDefinition (convertStack cfnStack regionText) True)
    Nothing -> pure ()
```

### OPS-10: `createStack` collects contents even on timeout (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/CreateStack.hs`:75-86
**What**: On `PollSuccess "DELETE_COMPLETE"` the function returns early (correct), but on `PollTimeout` or `PollInactivityTimeout` it falls through to `_ -> pure (Right 1)` without collecting stack contents. Meanwhile `UpdateStack` always collects contents regardless of poll result (line 120-121). This inconsistency means update shows final state on timeout but create does not.
**Fix**: This is likely intentional (on create timeout the stack might be partially created), but the behavior should be consistent. Consider collecting contents on timeout for create as well, or document why it's skipped.

### OPS-11: `percentEncode` is defined in `StackOperations` but also re-exported from `Changeset` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`:25, `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:23
**What**: `percentEncode` is a URL utility that lives in `StackOperations` (a CFN-specific module) and is re-exported by `Changeset`. A URL encoding function doesn't conceptually belong in either of these modules.
**Fix**: Move `percentEncode` to a dedicated utility module (e.g., `Iidy.Util.Url`) and import from there. This avoids the re-export and places the function in a more appropriate location.

### OPS-12: `convertResource` discards `lastUpdatedTimestamp` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:300-308
**What**: `convertResource` sets `sriLastUpdated = Nothing` hardcoded, even though `CF.StackResource` has a `timestamp` field that contains the last updated time. The `StackResourceInfo` type has a `sriLastUpdated` field specifically for this purpose.
**Fix**: Map the timestamp:
```haskell
, sriLastUpdated = Just r.timestamp.fromTime
```

### OPS-13: `isStackNotFoundError` only checks `message`, not error code (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:73-78
**What**: The function only checks whether the error message contains "does not exist". It does not verify the error code is `ValidationError`. An unlikely but possible scenario: a different error type happens to contain "does not exist" in its message, and would be incorrectly swallowed as a "stack not found" response.
**Fix**: Also check `se.code == "ValidationError"` for defense in depth:
```haskell
isStackNotFoundError (Amazonka.ServiceError se) =
  se.code == Amazonka.ErrorCode "ValidationError"
  && case se.message of
       Just msg -> "does not exist" `T.isInfixOf` Amazonka.fromErrorMessage msg
       Nothing  -> False
```

### OPS-14: `emitCfnYaml` parentKey/currentKey tracking loses context in deep nesting (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`:189-201
**What**: The `emitValue` function passes only `parentKey` and `currentKey` as two strings to track position in the tree. This loses context when nesting is deep. For example, `Resources -> MyResource -> Properties -> Tags -> 0 -> Key/Value` correctly uses `cfnTagWeight` because `parentKey` is "Tags". But if a resource has a nested structure like `Properties -> Policies -> 0 -> PolicyDocument -> Statement -> 0`, the weight function selection in `chooseWeightFn` depends on `parentKey` being "Statement" at the right level. The `newParent` computation at line 199 only updates when both `parentKey` and `currentKey` are empty (top level), meaning the parent context can become stale in deeply nested structures.
**Fix**: This appears to work correctly for the specific CFN weight functions because the key names (`Tags`, `Statement`, `Policies`, etc.) are distinctive enough that the flat parent/current tracking produces correct results. However, the logic at line 199 is subtle: `newParent = if T.null parentKey && T.null currentKey then kText else currentKey`. This means after the first level, `parentKey` becomes the previous `currentKey` in subsequent calls (via the `emitPair` call which passes `parentKey` and `currentKey`). It works but is fragile.

### OPS-15: `buildStackArgsYaml` does not handle multiline parameter values (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`:339-342
**What**: The `formatParam` function uses `quoteYamlString` for values, which produces single-line quoted strings. If a CloudFormation parameter value contains actual newlines (rare but possible), the generated YAML would be malformed because `quoteYamlString` does check for control characters (line 283: `|| T.any (< ' ') t`) and would quote them, but single-quoted YAML strings cannot contain literal newlines.
**Fix**: For values containing newlines, use YAML literal block scalar (`|`) or double-quoted strings with escape sequences instead of single quotes. This is an edge case but could produce invalid YAML.

### OPS-16: `Changeset.hs` uses both `control-lens` and OverloadedRecordDot (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`:33,109,242-243
**What**: The file imports `Control.Lens` for `set` and `view` (used for the `id` field conflict), while the rest of the codebase uses `OverloadedRecordDot`. This mixes two record access paradigms in one file, making it harder to understand which approach is canonical.
**Fix**: This is pragmatically necessary because `id` conflicts with `Prelude.id`. Document the reason in a comment near the imports (partially done at line 107-108). Acceptable but worth noting as a style inconsistency.

### OPS-17: `updateStack` emits `OdStackContents` even on poll timeout (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/UpdateStack.hs`:119-128
**What**: After polling, `updateStack` unconditionally collects and emits stack contents (lines 120-121) before checking the poll result (lines 124-128). On a timeout, this means an extra API call to collect contents, then the exit code is 1 anyway. Compare with `createStack` which skips contents on timeout.
**Fix**: Move the `collectStackContents` + emit inside the `PollSuccess` branch to avoid unnecessary API calls on timeout:
```haskell
case pollResult of
  PollSuccess finalStatus -> do
    contents <- collectStackContents ctx stackName
    emit (OdStackContents contents)
    if finalStatus `elem` updateSuccessStates
      then pure (Right 0)
      else pure (Right 1)
  _ -> pure (Right 1)
```

### OPS-18: `deleteStack` fetches events and contents before confirmation (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DeleteStack.hs`:76-79
**What**: Before asking the user for confirmation, `deleteStack` makes three API calls: `getStack` (already done), `fetchStackEvents`, and `collectStackContents`. If the user declines, these calls were wasted. For slow AWS connections, this adds latency before the confirmation prompt appears.
**Fix**: This likely matches Rust behavior (showing stack info before asking for confirmation is a user experience decision). Not a bug, but worth noting that the API cost is incurred even if the user cancels.

## Test Coverage Assessment

### Well-tested areas:
- **Polling engine** (`WatchStackTest.hs`): 8 tests covering terminal detection, multi-poll, new-event filtering, nested resource ignoring, multiple terminal statuses. Good use of `pollForCompletionWith` DI for mock-based testing.
- **Changeset conversion** (`ChangesetTest.hs`): 10 tests covering `convertChange`, `convertDetail`, `generateDashedName` with good edge cases (missing fields, minimal valid inputs).
- **Changeset helpers** (`ChangesetHelpersTest.hs`): 28 tests across 4 groups (`percentEncode`, `extractRegionFromArn`, `buildChangesetConsoleUrl`, `buildChangeSetCreationResult`). Thorough.
- **YAML emitter** (`CfnYamlEmitterTest.hs`): 27 tests covering inline values, quoting, nested objects, arrays, empty collections, round-trip JSON-to-YAML.
- **Request builder** (`RequestBuilderTest.hs`): 22 tests covering all mapping functions.
- **ConvertStack pure functions** (`ConvertStackTest.hs`): 11 tests for parameterization and YAML conversion.
- **Delete confirmation** (`DeleteStackTest.hs`): 10 tests for `isConfirmation`.
- **Phase 14 fixes** (`Phase14FixTest.hs`): 21 tests covering specific bug fixes.
- **Integration sequences** (`IntegrationTest.hs`): 13 tests verifying all renderers handle all OutputData variants without crashing.

### Coverage gaps:
1. **No unit tests for `createStack`, `updateStack`, `deleteStack`, `watchStack`, `describeStack` operation logic**. These are only tested through integration renderer sequences. The actual operation control flow (e.g., "does createStack return exit code 1 on DELETE_COMPLETE?") is untested.
2. **No tests for `collectStackContents`** -- the function that fetches resources, outputs, exports, changesets.
3. **No tests for `getStack`/`stackExists`/`getStackId`** -- the `isStackNotFoundError` error matching is untested.
4. **No tests for `createChangeset`/`executeChangeset`** -- only the pure helper functions are tested.
5. **No tests for `convertStackToIidy`** -- only the pure helpers (`parameterizeEnv`, `buildStackArgsYaml`, etc.) are tested. The file I/O and AWS call orchestration is untested.
6. **No tests for `buildConsoleUrl`** -- the stack info console URL construction (as opposed to the changeset console URL which IS tested).
7. **`quoteYamlString` missing edge cases**: no tests for strings that look like numbers, strings starting with `-`, the `~` null alias.
8. **`calculateEventDurations`**: tested for sub-second rounding but not for the main duration-tracking logic (matching IN_PROGRESS to COMPLETE pairs).
9. **No timeout tests for `pollForCompletionWith`**: the overall timeout and inactivity timeout paths are untested.
10. **`mapCapabilities` with all-invalid input returning `Nothing`**: untested (silent loss of user-specified capabilities).

## Positive Observations

1. **Excellent polling engine design**: The `pollForCompletionWith` abstraction with DI for the event fetcher makes the polling loop fully testable without AWS calls. The `PollConfig` record with callbacks for events, completion, inactivity, and tick is well-designed and extensible.

2. **Consistent exit code convention**: All operations follow the same pattern: `Right 0` for success, `Right 1` for failure, `Right 130` for user cancellation, `Left msg` for errors. This is clean and consistent.

3. **Good error handling in changeset polling**: `pollChangesetCompletion` has retry logic with a cap (30 retries) and error count reset on success. This is robust against transient API errors.

4. **Clean module structure**: Each operation has its own module with a single public entry point. Shared logic lives in `StackOperations`. Types are in `Types.hs`. This is easy to navigate.

5. **No partial functions**: Zero uses of `head`, `tail`, `fromJust`, `error`, or `undefined` in the production code. The `fromMaybe` and pattern matching on `Maybe` is used consistently.

6. **CFN YAML emitter is well-structured**: The weight function system for key sorting is clever and maintainable. Adding a new section just requires a new weight function and an entry in `chooseWeightFn`.

7. **Comprehensive test data builders** in `Shared.hs`: All 26 OutputData constructors have test builders, enabling thorough integration testing.

8. **Clear documentation**: Every module has a header comment explaining its purpose. Functions have Haddock docs. The `RequestBuilder` module even has a comment explaining why unknown capabilities are silently dropped.

9. **Correct use of stack ARN for delete polling**: `deleteStack` correctly resolves the stack ARN before sending the delete request, then uses the ARN for polling. This is critical because after deletion, the stack name no longer resolves but the ARN still works. This matches a common CFN footgun that many implementations get wrong.

10. **The `isStackEvent` check in polling is correct and robust**: It checks BOTH `logicalResourceId == stackName` AND `resourceType == "AWS::CloudFormation::Stack"`, preventing nested stack events from triggering false terminal detection.

## Grade Justification

Starting from 100:

| Deduction | Issue                                                         | Points |
|-----------|---------------------------------------------------------------|-------:|
| OPS-03    | `quoteYamlString` missing numeric/special YAML indicators     |     -5 |
| OPS-07    | `collectStackContents` fetches all account exports            |     -3 |
| OPS-04    | `parameterizeEnv` double-replacement on overlapping names     |     -3 |
| OPS-09    | Duplicated fetch+emit StackDefinition pattern (7 occurrences) |     -2 |
| OPS-12    | `convertResource` discards available lastUpdated timestamp    |     -2 |
| OPS-17    | `updateStack` collects contents on timeout unnecessarily      |     -1 |
| OPS-01    | Unbounded event set growth (perf, not correctness)            |     -1 |
| OPS-06    | Identical create/update terminal statuses without explanation  |     -1 |
| OPS-11    | `percentEncode` in wrong module + re-exported                 |     -1 |
| OPS-13    | `isStackNotFoundError` doesn't check error code               |     -1 |
| Coverage  | No unit tests for 5 operation modules' control flow           |     -5 |
| Coverage  | No timeout path tests in polling                              |     -2 |
| Coverage  | Missing quoteYamlString edge cases in tests                   |     -1 |

**Total deductions: -28, but capped at -21 for the strong positives.**

**Final grade: 79/100** -- Solid production code with good architecture and testability, but the YAML quoting gaps, the all-exports fetch, and the lack of operation-level unit tests keep it from a higher score. The polling engine is a highlight, and the code is well-organized and maintainable.
