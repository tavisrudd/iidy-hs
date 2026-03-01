# Code Review R6: CFN Operations & Polling

**Date**: 2026-03-01
**Round**: 6
**Scope**: CFN operations, polling engine, YAML emitter, changeset operations
**Prior reviews**: none (independent review)

## Grade: 81/100

## Summary

The CFN operations layer is well-structured with clean separation between pure conversion functions and IO operations. The polling engine is sound, with proper event deduplication via `Set`, correct terminal status detection filtering on both `logicalResourceId` and `resourceType`, and testable dependency injection via `pollForCompletionWith`. The YAML emitter handles CFN key ordering correctly and `quoteYamlString` covers the major YAML quoting pitfalls. The test suite is solid for the pure functions (changeset conversion, YAML emission, request builder mapping) but has significant gaps in IO-heavy operations and edge cases in the polling engine. The main correctness concern is that `updateStack` unconditionally calls `collectStackContents` even on poll timeout, unlike `createStack` which correctly skips it -- this could throw an exception or produce misleading output for a stack in a transitional state.

## Issues Found

### OPS-01: `updateStack` collects stack contents on poll timeout (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/UpdateStack.hs`:110-112
**What**: After polling completes, `updateStack` unconditionally calls `collectStackContents` and emits `OdStackContents` regardless of whether polling succeeded or timed out. Compare with `createStack` (lines 70-81) which correctly wraps `collectStackContents` inside the `PollSuccess` branch and skips it on timeout with the comment "stack may be partial".
**Fix**: Move lines 110-112 inside the `PollSuccess` branch, matching the pattern used in `createStack`:
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

### OPS-02: `isNoUpdatesError` does not check error code (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/UpdateStack.hs`:181-186
**What**: `isNoUpdatesError` only checks the message body for "No updates are to be performed" without verifying the error code is `ValidationError`. Compare with `isStackNotFoundError` in `StackOperations.hs` (lines 74-79) which checks both `se.code == Amazonka.ErrorCode "ValidationError"` AND the message text. A hypothetical future AWS error from a different service with the same substring in its message would be misidentified.
**Fix**: Add the error code check:
```haskell
isNoUpdatesError (Amazonka.ServiceError se) =
  se.code == Amazonka.ErrorCode "ValidationError"
  && case se.message of
       Just msg -> noUpdatesMessage `T.isInfixOf` Amazonka.fromErrorMessage msg
       Nothing  -> False
```

### OPS-03: `buildEventsDisplay` has unused parameter `_sName` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs`:131
**What**: The first parameter `_sName` is a dead parameter -- the function never uses it, but all 4 callers pass a stack name. This is dead code in the function signature.
**Fix**: Remove the parameter: `buildEventsDisplay :: Int -> [CF.StackEvent] -> StackEventsDisplay` and update all callers to drop the stack name argument. Or if the parameter is intended for future use, add a TODO comment explaining why.

### OPS-04: Redundant title override in `executeChangeset` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`:191-192
**What**: The code calls `buildEventsDisplay stackName 10 prevEvents` which already sets `sedTitle = "Previous Stack Events (max 10):"`, then immediately overrides it with the identical string: `eventsDisplay { sedTitle = "Previous Stack Events (max 10):" }`. This is a no-op.
**Fix**: Remove the title override -- just use `eventsDisplay` directly:
```haskell
let eventsDisplay = buildEventsDisplay stackName 10 prevEvents
emit (OdStackEvents eventsDisplay)
```

### OPS-05: `buildEventsDisplay` traverses event list twice (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs`:132-143
**What**: The function calls `length events` (full traversal) and then `take numEvents events` (partial traversal). For CloudFormation stacks with many events (which are already paginated and could be thousands), this is an unnecessary double traversal.
**Fix**: Use `splitAt` to get both results in a single traversal:
```haskell
let (taken, rest) = splitAt numEvents events
    total = numEvents + length rest
```

### OPS-06: Polling loop event set grows unboundedly (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:284-286
**What**: The `lastEventSet` accumulates all event IDs seen across every poll cycle via `Set.union lastEventSet newEventIds`. For a long-running operation (e.g., 500+ resources in a nested stack), this set grows without bound. Since CloudFormation event IDs are unique UUIDs, each poll cycle adds new entries that are never removed.
**Fix**: This is acceptable in practice since CloudFormation operations typically produce at most a few hundred events. However, an alternative would be to only track the most recent event timestamp and filter by timestamp instead of event ID set, which would be O(1) memory. Not urgent.

### OPS-07: `percentEncode` lives in `StackOperations` and is re-exported by `Changeset` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:352-362, `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`:25,65
**What**: A URL percent-encoding function is defined in `StackOperations` (a CFN-specific module) and re-exported by `Changeset` for use in `DescribeStack`. The function has no CFN-specific logic and would be better placed in a general utility module.
**Fix**: Move to `Iidy.Util.Url` or similar and import from there. This eliminates the re-export chain and places the function in a semantically appropriate module.

### OPS-08: `deleteStack` return type allows `Left` but never returns it (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DeleteStack.hs`:49-111
**What**: The return type is `IO (Either Text Int)`, but the function only ever returns `Right 0`, `Right 130`, or `Right 1`. The `Left` variant is never used. If an AWS error occurs (e.g., permission denied on DeleteStack), it propagates as an exception rather than being caught and returned as `Left`. This is inconsistent with the function signature which suggests error-as-value.
**Fix**: Either catch AWS exceptions and return `Left` (matching `createChangeset` which catches errors), or narrow the return type. Since the caller in `Main.hs` likely has a top-level exception handler, this is more of a documentation/consistency issue.

### OPS-09: `ConvertStack` uses `hPutStrLn stderr` instead of the output pipeline (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`:448,454,461,490,540,548
**What**: The `convertStackToIidy` function writes progress messages directly to stderr via `hPutStrLn stderr` ("Wrote stack-policy.json", etc.) instead of using the `OutputData`/`emit` pattern used by all other operations. This bypasses the output pipeline and wouldn't work correctly with JSON output mode.
**Fix**: Accept an `emit` callback and use `OdStatusUpdate` or a dedicated `OdConvertProgress` constructor for these messages. Or, since this is a one-shot file-writing operation (not a long-running cloud operation), the direct stderr approach may be intentionally simpler -- if so, document this as a known divergence.

### OPS-10: `Changeset.hs` imports `Data.Vector` for two small constant lists (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`:37, 389-406
**What**: `Data.Vector` is imported solely for the `adjectives` and `nouns` lists in `generateDashedName`. These are small constant lists (20 elements each) where plain Haskell lists would perform identically since the `randomRIO` indexing is O(n) on lists but the n is only 20.
**Fix**: Replace `V.Vector Text` with `[Text]` and use `(!!)` or a safe indexing wrapper, or keep as-is since this is a micro-optimization that doesn't matter in practice. The Vector is at least correct and safe.

### OPS-11: `quoteYamlString` does not handle multi-line strings correctly (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`:280-320
**What**: The function detects control characters (line 288: `T.any (< ' ') t`) and quotes them with single quotes. However, in YAML, single-quoted scalars cannot contain literal newlines or other control characters -- they must be represented with double-quoted strings (which allow escape sequences like `\n`). If a CFN parameter value contains a newline, the generated YAML would be syntactically invalid.
**Fix**: When control characters are detected, use double-quoting with proper escape sequences instead of single-quoting. This is unlikely in practice (CFN parameter values rarely contain newlines) but is a correctness issue for the general case.

### OPS-12: `calculateEventDurations` accumulates results in reverse order (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs`:175-192
**What**: The `go` helper prepends `(seEventId e, dur)` to the accumulator (line 192), building the list in reverse chronological order. This is fine for the `Map.fromList` on line 172 since map construction doesn't depend on list order. However, if a duplicate `seEventId` exists (theoretically impossible but defensively), `Map.fromList` would keep the last occurrence, which would be the earliest event chronologically. This is a theoretical concern only.
**Fix**: No fix needed -- event IDs are unique UUIDs from AWS. Noting for completeness.

### OPS-13: `WatchStack` calls `getStack` then `getStackId` making two DescribeStacks calls (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/WatchStack.hs`:49-61
**What**: The function calls `getStack ctx stackName` (line 49), pattern matches on the result to get the `cfnStack`, then calls `getStackId ctx stackName` (line 60) which internally calls `getStack` again. The stack ID is already available from the first call via `cfnStack.stackId`.
**Fix**: Extract the stack ID from the already-fetched stack:
```haskell
let sId = fromMaybe stackName (cfnStack.stackId)
```
This eliminates one unnecessary DescribeStacks API call.

### OPS-14: `extractRegionFromArn` silently defaults to us-east-1 for non-ARN inputs (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`:337-340
**What**: When the input is not a valid ARN (e.g., a stack name instead of a stack ID), the function silently returns "us-east-1". The comment says "Fallback matches Rust; ARNs from AWS are always well-formed" -- but `buildChangeSetCreationResult` calls this with `csiStackId info`, which could be empty if the changeset has no stack ID.
**Fix**: This matches Rust behavior and is acceptable as documented. The empty-string case would produce `extractRegionFromArn "" = us-east-1` which is the intended fallback.

## Test Coverage Assessment

### Well-tested areas:
- **Polling engine** (`WatchStackTest.hs`): 13 tests covering terminal status detection, multi-poll scenarios, event deduplication, non-stack resource filtering, various terminal statuses. Good use of `pollForCompletionWith` for testable DI.
- **Changeset conversion** (`ChangesetTest.hs`): 10 tests covering `convertChange`, `convertDetail`, `generateDashedName` with edge cases (missing fields, minimal valid input).
- **Changeset helpers** (`ChangesetHelpersTest.hs`): 28 tests across 4 groups (`percentEncode`, `extractRegionFromArn`, `buildChangesetConsoleUrl`, `buildChangeSetCreationResult`). Thorough.
- **YAML emitter** (`CfnYamlEmitterTest.hs`): 35+ tests covering scalars, nesting, arrays, empty collections, string quoting, number formatting, templateBodyToYaml round-trips.
- **Request builder** (`RequestBuilderTest.hs`): 20 tests covering capability mapping, parameter/tag conversion, onFailure mapping. Clean.
- **ConvertStack** (`ConvertStackTest.hs`): 11 tests covering parameterization, template conversion, stack-args YAML generation.

### Gaps in test coverage:
1. **No poll timeout tests**: `PollTimeout` and `PollInactivityTimeout` results are never tested. The polling engine has timeout logic (lines 248-262 of StackOperations.hs) that is completely untested.
2. **No tests for `pcWaitForStatusChange = True` behavior**: The watch-stack-specific behavior where polling waits for new events before checking terminal status is untested via `pollForCompletionWith`.
3. **No tests for `isNoUpdatesError`**: This error-detection function is exported for testing but has no tests.
4. **No tests for `isStackNotFoundError`**: Same -- exported and testable but untested.
5. **No tests for `convertOutput`**: The Maybe-returning conversion function for stack outputs is untested.
6. **No tests for `convertChangeSetSummary`**: Returns Nothing when name or ID is missing -- untested.
7. **No tests for `buildConsoleUrl`**: The stack console URL builder is untested (only the changeset variant is tested).
8. **No tests for `convertStack`**: The CF.Stack-to-StackDefinition conversion is untested.
9. **No integration-level tests for `createStack`/`updateStack`/`deleteStack`**: These require AWS mocking, which is understandably harder, but the control flow branches (timeout, DELETE_COMPLETE, no-updates) are only tested indirectly.
10. **No tests for `calculateEventDurations` edge cases**: The function is used in `buildEventsDisplay` but only tested indirectly. Edge cases like events without timestamps, overlapping IN_PROGRESS events for the same resource, or events with no matching start time are untested.
11. **No tests for `quoteYamlString` with actual control characters**: The function claims to handle `T.any (< ' ') t` but no test exercises this path (e.g., strings containing `\n`, `\t`, `\0`).
12. **No tests for `emitCfnYaml` with CFN-specific key sorting**: The `chooseWeightFn` function for Parameters, Resources, Tags, Outputs, IAM statements, policy documents is untested -- only top-level document sorting is tested.

## Positive Observations

1. **Clean separation of pure and IO code**: All conversion functions (`convertEvent`, `convertStack`, `convertChange`, `convertDetail`, `convertEventWithDuration`, `calculateEventDurations`, `buildEventsDisplay`, `percentEncode`, `extractRegionFromArn`) are pure and independently testable. This is excellent Haskell design.

2. **Dependency injection for testability**: The `pollForCompletionWith` function takes an `IO [CF.StackEvent]` action instead of a `CfnContext`, enabling mock-based testing without AWS. This is well-designed.

3. **Correct event deduplication**: The polling loop uses `Set.notMember` with event IDs for O(log n) deduplication per event. The watch-stack module adds a second dedup layer for events seen before polling started. Both are correct.

4. **Robust `isStackEvent` check**: Filtering on both `logicalResourceId == stackName` AND `resourceType == "AWS::CloudFormation::Stack"` prevents nested stack events from being mistaken for the top-level stack's terminal status. This is a subtle and important correctness detail.

5. **Consistent exit code convention**: All operations follow the same pattern: `Right 0` for success, `Right 1` for failure, `Right 130` for user cancellation. This is clean and well-documented.

6. **Well-documented code**: Nearly every function has a Haddock comment explaining its purpose, steps, and edge cases. Module headers explain the module's role.

7. **Correct `percentEncode` implementation**: UTF-8 encodes via `TE.encodeUtf8` then percent-encodes raw bytes, correctly handling multi-byte Unicode code points. The RFC 3986 unreserved character check operates on `Word8` values.

8. **`quoteYamlString` is comprehensive**: Handles YAML 1.1 booleans (yes/no/true/false), null aliases (~), number-like strings, dot-prefixed floats (.inf/.nan), leading/trailing spaces, control characters, and block sequence indicators (- prefix). The single-quote escaping ('' for embedded quotes) is correct.

9. **Proper pagination**: `collectStackContents` correctly paginates ListChangeSets and ListExports using conduit, matching the Rust implementation. The comment about ListExports having no server-side stack filter is helpful.

10. **Shared poll config**: `mkStandardPollConfig` extracts the common polling pattern and operations override specific fields as needed (e.g., watch-stack adds `pcWaitForStatusChange`).

## Grade Justification

| Deduction | Reason                                                                              |
|----------:|:------------------------------------------------------------------------------------|
|        -5 | OPS-01: `updateStack` collects contents on timeout (correctness bug)                |
|        -2 | OPS-02: `isNoUpdatesError` missing error code check (defense in depth)              |
|        -1 | OPS-03: Dead parameter `_sName` in `buildEventsDisplay`                             |
|        -1 | OPS-04: Redundant title override in `executeChangeset`                              |
|        -1 | OPS-05: Double traversal in `buildEventsDisplay`                                    |
|        -1 | OPS-07: `percentEncode` in wrong module with re-export chain                        |
|        -1 | OPS-08: `deleteStack` return type suggests `Left` but never returns it              |
|        -2 | OPS-09: `ConvertStack` bypasses output pipeline                                     |
|        -1 | OPS-11: `quoteYamlString` single-quoting with control characters is invalid YAML    |
|        -1 | OPS-13: `WatchStack` makes redundant DescribeStacks API call                        |
|        -3 | Test gap: No timeout/inactivity polling tests                                       |
|        -1 | Test gap: Several pure helper functions untested (`isNoUpdatesError`, `convertOutput`, `convertChangeSetSummary`, `buildConsoleUrl`, `convertStack`) |
| **Total** | **81/100**                                                                          |

Starting from 100, total deductions: 19 points. The codebase is well-architected with clean separation of concerns, good Haskell idioms, and solid documentation. The main concerns are one correctness bug in `updateStack` timeout handling, missing error code validation in `isNoUpdatesError`, and significant test coverage gaps around the polling timeout paths and several pure conversion functions.
