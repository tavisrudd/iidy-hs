# Code Review R10: CFN Operations & Polling

**Date**: 2026-03-01
**Round**: 10
**Scope**: CFN operations, polling engine, YAML emitter, changeset operations
**Prior reviews**: none (independent review)
**Note**: Architectural items listed in known-deferred list are excluded from this review.

## Grade: 87/100

## Summary

The 12 production files and 7 test files (plus CfnYamlEmitterTest and DeleteStackTest) form a well-structured CloudFormation operations layer. The code is generally clean, well-documented, and follows consistent patterns across all operation modules. The polling engine is well-designed with dependency injection (pollForCompletionWith) enabling testability. The YAML emitter is impressively complete with CFN-specific key sorting. Several minor issues exist around edge cases, misleading variable names, and test coverage gaps for timeout branches.

## Issues Found

### OPS-01: watchStack emits empty OdNewStackEvents on second-dedup filtering (Severity: Minor)
**File**: src/Iidy/Cfn/Operations/WatchStack.hs:71-74
**What**: The `pcOnNewEvents` callback in watchStack filters events against `seenIds` (pre-polling events), but then unconditionally calls `pcOnNewEvents baseCfg fresh`. When `fresh` is empty (all new events were already in the initial batch), this emits `OdNewStackEvents []` to the renderer. While renderers likely handle empty lists gracefully, it produces unnecessary output emissions.
**Fix**: Add a guard: `when (not (null fresh)) $ pcOnNewEvents baseCfg fresh`

### OPS-02: Misleading `isDelete` variable in pollForCompletionWith (Severity: Nitpick)
**File**: src/Iidy/Cfn/StackOperations.hs:275
**What**: `isDelete = "DELETE_COMPLETE" `elem` terminalStatuses` is always True for all current callers because `allTerminalStatuses` (which all terminal status lists include or are) contains `"DELETE_COMPLETE"`. The variable name suggests it indicates a delete operation, but it's really "does the terminal status list include DELETE_COMPLETE" which is always true. The actual guard is `isDelete && currentStatus == "DELETE_COMPLETE"`, which is functionally equivalent to just `currentStatus == "DELETE_COMPLETE"`. The logic is correct but the variable adds confusion.
**Fix**: Simplify to `ociSkipRemainingSections = currentStatus == "DELETE_COMPLETE"`

### OPS-03: First poll cycle in createStack/updateStack/deleteStack may emit pre-existing events (Severity: Minor)
**File**: src/Iidy/Cfn/StackOperations.hs:285
**What**: `pollForCompletionWith` starts with `go Set.empty`, meaning the first poll cycle treats ALL returned events as new. For `createStack`, this is fine (stack is brand new). For `updateStack` and `deleteStack`, if the stack has pre-existing events from a prior operation, these will all be emitted as "new" events in the first poll callback. The `watchStack` operation handles this correctly with its double-dedup layer, but the other write operations do not have this protection.
**Fix**: Accept an optional initial event ID set in PollConfig (e.g., `pcInitialSeenEventIds :: Set.Set Text`) and use it as the starting set for `go`. Alternatively, fetch events once before polling begins and seed the set.

### OPS-04: describeChangeset error handling catches all Amazonka.Error as Text (Severity: Minor)
**File**: src/Iidy/Cfn/Operations/Changeset.hs:229-230
**What**: `describeChangeset` catches `Amazonka.Error` and converts to `Left (T.pack (show e))`. The `show` representation of amazonka errors is verbose and implementation-specific (includes HTTP status codes, headers, etc.). This is consumed by `pollChangesetCompletion` on line 133 where it may end up in the `csiStatusReason` field visible to users after max retries.
**Fix**: Extract a cleaner error message from the Amazonka.Error, similar to how `isNoUpdatesError` and `isStackNotFoundError` access `se.message`.

### OPS-05: pollChangesetCompletion retry does not distinguish transient vs permanent errors (Severity: Minor)
**File**: src/Iidy/Cfn/Operations/Changeset.hs:128-148
**What**: The retry loop in `pollChangesetCompletion` treats all errors from `describeChangeset` the same way, retrying up to 30 times. Some errors are transient (throttling, network timeout) but others are permanent (changeset not found, access denied). Permanent errors waste 60 seconds of retries before returning a synthetic FAILED ChangeSetInfo.
**Fix**: Check the error type from `describeChangeset` and fail fast on non-retryable errors (e.g., ChangeSetNotFoundException, AccessDeniedException).

### OPS-06: `notificationARNs` field access inconsistency (Severity: Nitpick)
**File**: src/Iidy/Cfn/Operations/DescribeStack.hs:102 vs src/Iidy/Cfn/RequestBuilder.hs:67
**What**: In `convertStack` (DescribeStack.hs:102), the field is accessed as `s.notificationARNs` which returns `Maybe [Text]`, and wrapped with `fromMaybe [] s.notificationARNs`. In `buildCreateStackRequest` (RequestBuilder.hs:67), `saNotificationArns` is passed as `Maybe [Text]` directly. The types are consistent, but the casing inconsistency (`notificationARNs` from AWS vs `saNotificationArns` in StackArgs) could cause confusion. This is just a naming observation, not a bug.
**Fix**: None needed -- this follows amazonka naming conventions.

### OPS-07: `deleteStack` confirmation uses `String` not `Text` for prompt (Severity: Nitpick)
**File**: src/Iidy/Cfn/Operations/DeleteStack.hs:87
**What**: `requestConfirmation` accepts `String`, forcing the caller to use `T.unpack stackName`. The project coding standard prefers `Text` over `String`. The `Iidy.Confirm` module uses `String` throughout (putStr, getLine).
**Fix**: Consider a `Text`-based API in `Iidy.Confirm`, or accept this as an IO boundary decision.

### OPS-08: `convertDescribeResponse` accesses `resp.status` without Maybe unwrap (Severity: Nitpick)
**File**: src/Iidy/Cfn/Operations/Changeset.hs:243
**What**: `csiStatus = CF.fromChangeSetStatus resp.status` -- in the amazonka type, `DescribeChangeSetResponse.status` is `ChangeSetStatus` (not `Maybe ChangeSetStatus`), so this is correct. Not a real issue, but worth calling out that this differs from `resp.executionStatus` on line 246 which IS wrapped in Maybe.
**Fix**: None needed.

## Test Coverage Assessment

### Well-tested pure functions:
- `stackNameFromId`: 3 tests covering ARN, plain name, slash-separated
- `isStackNotFoundError`: 6 tests covering positive, negative, edge cases
- `isNoUpdatesError`: 5 tests (in WatchStackTest) + 3 tests (in Phase14FixTest)
- `pollForCompletionWith`: 6 tests covering terminal detection, multi-poll, callback filtering, nested resource filtering, DELETE_COMPLETE, rollback
- `calculateEventDurations`: 7 tests covering matching pairs, floor clamp, missing start, empty, FAILED, multi-resource, no-timestamp
- `convertEventWithDuration`: 3 tests covering sub-second clamp, exact seconds
- `buildConsoleUrl`: 3 tests covering URL structure, encoding, multi-region
- `convertChange`: 5 tests covering Nothing, missing fields, valid extraction, minimal
- `convertDetail`: 2 tests covering populated and empty
- `generateDashedName`: 3 tests covering format, non-empty, variety
- `percentEncode`: 11 tests covering empty, ASCII, digits, unreserved, reserved chars, ARN, space, hash, Unicode
- `extractRegionFromArn`: 6 tests covering multiple regions, changeset ARN, fallback
- `buildChangesetConsoleUrl`: 5 tests covering URL structure, encoding, regions
- `buildChangeSetCreationResult`: 10 tests covering type, name, status, changes, URL, next steps
- `parameterizeEnv`: 2 tests covering known environments and unknown
- `parameterizeStackName`: 3 tests covering digits, no digits, project only
- `templateBodyToYaml`: 4 tests covering JSON, YAML, sorting, unsorted
- `buildStackArgsYaml`: 2 tests covering basic and SSM params
- `quoteYamlString`: 25+ tests covering booleans, numbers, special chars, control chars, YAML specials
- `inlineValue`: 10+ tests covering numbers, booleans, null, empty collections, strings
- `emitCfnYaml`: 12+ tests covering scalars, nesting, arrays, empty collections, objects in arrays
- `isConfirmation`: 10 tests covering y/Y/yes/YES/Yes, negatives, edge cases
- `mapCapability`/`mapCapabilities`: 5 tests covering known values, case insensitivity, unknown
- `mapParameters`/`mapTags`: 4 tests covering Nothing, empty, non-empty
- `mapOnFailure`: 5 tests covering known values, case insensitivity, Nothing, unknown

### Gaps in test coverage:

1. **PollTimeout branch**: No test exercises `pcTimeoutSeconds` to verify `PollTimeout` is returned when the overall timeout elapses. The `pollForCompletionWith` tests only cover the terminal-status path.

2. **PollInactivityTimeout branch**: No test exercises `pcInactivityTimeoutSecs` to verify `PollInactivityTimeout` is returned. The `pcWaitForStatusChange` interaction with inactivity timeout is also untested.

3. **buildEventsDisplay**: Not directly tested. The truncation logic (splitting events, generating TruncationInfo) is only exercised indirectly through the renderer tests.

4. **convertEvent** (DescribeStack.hs:147-159): Not directly tested. It's exercised indirectly through `calculateEventDurations` and `convertEventWithDuration` tests, but no test verifies field mapping from CF.StackEvent to StackEvent.

5. **convertStack** (DescribeStack.hs:88-123): Not tested. This is the CF.Stack to StackDefinition conversion, which involves capability text extraction, tag/parameter map building, and console URL construction. Requires constructing amazonka CF.Stack values.

6. **convertResource**, **convertOutput**, **convertChangeSetSummary** (StackOperations.hs:306-340): Not directly tested. These convert amazonka types to output types.

7. **emitStackDefinition** (DescribeStack.hs:242-248): Not tested. Simple enough (fetch + emit), but the Nothing path (no-op on missing stack) is uncovered.

8. **checkStackState** and **findPendingChangeset** (Changeset.hs:353-381): Not tested. These are IO-heavy but `checkStackState` has logic (DELETE_COMPLETE -> DoesNotExist, REVIEW_IN_PROGRESS -> pending changeset lookup) that could be tested with mocks.

## Positive Observations

1. **Excellent polling engine design**: The `pollForCompletionWith` dependency injection pattern is a textbook example of making IO-heavy code testable. The `PollConfig` record with callbacks is clean and extensible.

2. **Thorough YAML emitter**: The `emitCfnYaml` function with CFN-specific key sorting (8 weight functions for different contexts) is impressively complete. The `chooseWeightFn` dispatching based on parent/current key context is well thought out.

3. **Consistent error handling patterns**: All operations follow the same pattern of `try`/`catch` for AWS errors, with specific error checks (isNoUpdatesError, isStackNotFoundError) using both error code and message matching.

4. **Clean module boundaries**: Each operation module has a focused responsibility. Shared logic (mkStandardPollConfig, emitStackDefinition, buildEventsDisplay) is properly extracted to DescribeStack.hs and StackOperations.hs.

5. **Comprehensive quoteYamlString**: The YAML string quoting logic handles an impressive number of edge cases (control chars, YAML booleans, numbers, dash sequences, tilde, dot-prefixed floats, leading quotes) with clear code structure and thorough tests.

6. **Good use of event deduplication**: The Set-based event ID tracking in the polling loop is efficient (O(log n) per event) and the watchStack double-dedup layer is a correct solution for the "initial events already shown" problem.

7. **Well-structured test files**: Tests are organized into logical groups with descriptive names. Test helpers (mkStackEvt, mkResourceEvt, mkAwsServiceError) reduce boilerplate and improve readability.

8. **Proper pagination**: All API calls that can return multiple pages (ListChangeSets, ListExports, DescribeStackEvents, DescribeStackResourceDrifts) use proper pagination via conduit or manual nextToken handling.

9. **Defensive coding**: Consistent use of `fromMaybe` for optional AWS fields, proper `Maybe` threading through conversion functions, and explicit handling of missing stacks across all operations.

10. **Clear documentation**: Every module has a header doc comment explaining its purpose, and the step-by-step comments in each operation function make the flow easy to follow.

## Grade Justification

Starting from 100:

| Deduction | Issue                                                      |
|----------:|:-----------------------------------------------------------|
|        -2 | OPS-01: Empty event emission in watchStack dedup           |
|        -1 | OPS-02: Misleading isDelete variable (clarity)             |
|        -3 | OPS-03: Pre-existing events emitted in first poll cycle    |
|        -2 | OPS-04: Verbose show-based error message in describeChangeset |
|        -2 | OPS-05: No transient vs permanent error distinction in retry |
|        -1 | OPS-07: String/Text inconsistency in confirmation prompt   |
|        -2 | Test gap: PollTimeout/PollInactivityTimeout untested       |

**Final: 87/100**
