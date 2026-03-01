# Code Review R11: CFN Operations & Polling

**Date**: 2026-03-01
**Round**: 11
**Scope**: CFN operations, polling engine, YAML emitter, changeset operations
**Prior reviews**: none (independent review)
**Note**: Architectural items listed in known-deferred list are excluded from this review.

## Grade: 85/100

## Summary

The CFN operations and polling engine is well-structured and competently implemented. The code follows a consistent pattern across all operations (build request, send, poll, collect contents, emit). The polling engine with dependency injection (`pollForCompletionWith`) is testable and thoroughly exercised. The YAML emitter and changeset operations are solid. Test coverage is good for pure functions but has some gaps in edge-case coverage. A few minor logic issues exist in edge-case handling around `DELETE_COMPLETE` during updates and elapsed time reporting.

## Issues Found

### OPS-01: updateStack does not handle DELETE_COMPLETE before collecting contents (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/UpdateStack.hs`:111-117
**What**: When `pollForCompletion` returns `PollSuccess "DELETE_COMPLETE"` (possible since `updateTerminalStatuses` inherits it from `allTerminalStatuses`), `updateStack` falls through to `collectStackContents` on a deleted stack. `createStack` (line 71) correctly short-circuits to `Right 1` for this case. While unlikely in practice (requires external deletion during update), this is an unnecessary API call that could log confusing empty results.
**Fix**: Add a `PollSuccess "DELETE_COMPLETE" -> pure (Right 1)` guard before the general `PollSuccess` case, matching `createStack`.

### OPS-02: OperationCompleteInfo elapsed time measures from polling start, not operation start (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:228,274-277
**What**: `pollForCompletionWith` uses `getCurrentTime` as `startTime` when `pcStartTime` is `Nothing` (the default from `defaultPollConfig`). `mkStandardPollConfig` does not override `pcStartTime`. This means `ociElapsedSeconds` and `ociOperationStartTime` in `OperationCompleteInfo` reflect polling start time, not the actual operation start time (`cfnStartTime ctx`). The same applies to `InactivityTimeoutInfo`. Meanwhile, event durations via `convertEventWithDuration` correctly use `cfnStartTime ctx`, creating an inconsistency.
**Fix**: Have `mkStandardPollConfig` set `pcStartTime = Just (cfnStartTime ctx)` so all timing is relative to the true operation start.

### OPS-03: pollChangesetCompletion has no upper bound on successful retries (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`:130-146
**What**: The changeset polling loop (`pollChangesetCompletion`) resets `errorCount` to 0 on any successful response (line 146). But there is no overall timeout or iteration cap. If the changeset stays in a non-terminal state indefinitely (e.g., stuck in `CREATE_PENDING`), this will poll forever. The error budget of 30 retries only covers consecutive errors.
**Fix**: Add an overall iteration cap or total time budget. For example, fail after 300 iterations (600 seconds) with a descriptive message.

### OPS-04: `DELETE_SKIPPED` and `REVIEW_IN_PROGRESS` in createTerminalStatuses/updateTerminalStatuses are suspicious (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Context.hs`:135-144
**What**: `DELETE_SKIPPED` and `REVIEW_IN_PROGRESS` are appended to `createTerminalStatuses` and `updateTerminalStatuses`. These are not standard CloudFormation stack statuses that would be returned in `DescribeStackEvents` for the stack resource. `DELETE_SKIPPED` is a resource-level status used during stack deletion, and `REVIEW_IN_PROGRESS` is an initial stack state for changeset-created stacks. Including them as terminal statuses for `create`/`update` polling is unlikely to cause harm (they'd never be the top-level stack event status during those operations), but they are conceptually wrong.
**Fix**: Remove these from `createTerminalStatuses` and `updateTerminalStatuses`, or add a comment explaining why they are there (e.g., safety net against edge cases).

### OPS-05: Duplicate `mkEvent` definition in test and shared modules (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/test/Test/DescribeStackTest.hs`:18-30 and `/home/tavis/src/iidy-hs/test/Test/Shared.hs`:126-139
**What**: `mkEvent` is defined identically in both `Test.DescribeStackTest` and `Test.Shared`. The `Phase14FixTest` module imports from `Test.Shared`, but `DescribeStackTest` defines its own local copy.
**Fix**: `DescribeStackTest` should import `mkEvent` from `Test.Shared` and remove its local definition.

### OPS-06: `newEvents` callback receives events in reverse chronological order (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:242
**What**: The `pcOnNewEvents` callback receives `reverse newEvents` where `newEvents` was filtered from `events` (which comes from `fetchStackEvents`, documented as "most recent first per page"). The `reverse` converts to chronological order (oldest first), which is correct for display. However, `newEvents` is filtered from the full `events` list, preserving the original (most-recent-first) order, so `reverse` correctly yields chronological. This is fine but could be clearer with a comment.
**Fix**: No code change needed. A brief comment like `-- reverse: events arrive most-recent-first; emit oldest-first` would help.

### OPS-07: `quoteYamlString` does not handle strings starting with `%` (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`:314
**What**: The `needsQuoting` function checks for `%` in `T.any (...) t`, which handles strings containing `%` anywhere. But YAML 1.1 also treats `%` as a directive indicator when it appears at the start of a line. Since this is a YAML 1.1 concern and the emitter is used for inline values (not multi-line), and `%` is already included in the check characters, this is correctly handled. No actual issue.
**Fix**: None needed. Noting this for completeness.

### OPS-08: `buildStackArgsYaml` uses raw string concatenation for YAML, risking injection (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`:362-397
**What**: `buildStackArgsYaml` builds YAML content via string concatenation. While parameter values go through `quoteYamlString`, the `stackName` (after `parameterizeStackName`) and `project` name are used raw in the output. If a stack name or project name contained YAML-special characters (e.g., `:`), it would produce invalid YAML. In practice, CloudFormation stack names are restricted to alphanumeric + hyphens, so this is unlikely to be exploitable, but it's a latent fragility.
**Fix**: Apply `quoteYamlString` to the parameterized stack name and project name in the YAML output, or add a comment noting the CFN naming constraint makes this safe.

### OPS-09: `convertStack` constructs `notifArns` but never uses it when `saNotificationArns` is `Nothing` vs empty list (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs`:102,118
**What**: `notifArns = fromMaybe [] s.notificationARNs` correctly defaults to empty list when the field is `Nothing`. The result is stored in `sdNotificationArns`. This is correct behavior; noting for completeness that the `Maybe` wrapper is properly unwrapped.
**Fix**: None needed.

### OPS-10: `deleteStack` user-cancelled returns exit code 130 but other operations return it inconsistently (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DeleteStack.hs`:89, `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/UpdateStack.hs`:167, `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/CreateOrUpdate.hs`:109,151
**What**: All four places returning `Right 130` for user cancellation are consistent, which is good. The value 130 is the Unix convention for SIGINT. This is a positive observation rather than an issue.
**Fix**: None needed.

### OPS-11: `pollDriftDetection` has no retry or timeout mechanism (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStackDrift.hs`:118-126
**What**: `pollDriftDetection` recursively calls itself with a 3-second delay when detection is in progress, but has no upper bound on retries or total elapsed time. If the drift detection never completes (e.g., AWS API issue), this will poll indefinitely. Unlike `pollChangesetCompletion` which at least has error retry logic, this has nothing.
**Fix**: Add a maximum iteration count (e.g., 100 = 300 seconds = 5 minutes) and return a descriptive error or emit a timeout event when exceeded.

## Test Coverage Assessment

### Well-tested pure functions:
- `stackNameFromId`: 3 cases covering ARN format, plain name, and slashes
- `isStackNotFoundError`: 6 cases covering positive, negative, missing message, wrong code, non-ServiceError
- `isNoUpdatesError`: 5 cases covering positive, substring, wrong code, wrong message, non-ServiceError (plus 3 more in Phase14FixTest)
- `percentEncode`: 10 cases covering empty, ASCII, digits, unreserved, reserved chars, Unicode
- `extractRegionFromArn`: 6 cases covering various regions and malformed ARNs
- `buildChangesetConsoleUrl`: 5 cases
- `buildChangeSetCreationResult`: 10 cases covering UPDATE/CREATE type, fields, hasChanges
- `convertChange`/`convertDetail`: 7 cases covering Nothing, missing fields, valid changes
- `generateDashedName`: 3 cases covering format, non-empty, variety
- `formatAmazonkaError`/`isNonRetryableError`: 6 cases
- `calculateEventDurations`: 7 cases covering matching pairs, floor clamp, no match, empty, FAILED, multiple resources, no timestamp
- `convertEventWithDuration`: 3 cases covering sub-second, exact seconds
- `buildConsoleUrl`: 3 cases
- `mapCapability`/`mapCapabilities`/`mapParameters`/`mapTags`/`mapOnFailure`: 21 cases
- `quoteYamlString`: 23+ cases covering booleans, numbers, special chars, control chars, dash sequences
- `emitCfnYaml`: 12 cases covering scalars, nesting, arrays, empty collections
- `parameterizeEnv`/`parameterizeStackName`/`templateBodyToYaml`/`buildStackArgsYaml`: 10 cases
- `pollForCompletionWith`: 8 cases covering terminal detection, multi-poll, callback filtering, nested resources, DELETE_COMPLETE, UPDATE_ROLLBACK_COMPLETE, overall timeout, inactivity timeout

### Gaps in test coverage:
1. **`pollForCompletionWith` with `pcWaitForStatusChange = True`**: No test covers the watch-stack scenario where `pcWaitForStatusChange` is set and the poller should wait for new events before checking terminal status. The existing timeout test uses `pcWaitForStatusChange = False`.
2. **`convertStack`**: No tests for the `DescribeStack.convertStack` function that maps `CF.Stack` to `StackDefinition`. This is a pure function with significant logic (capability extraction, tag mapping, parameter mapping, console URL construction).
3. **`buildEventsDisplay`**: No tests for truncation behavior (what happens when events exceed `numEvents`), or for the title/truncation info fields.
4. **`collectStackContents`**: No unit tests. This is IO-heavy, but the conversion helpers it calls (`convertResource`, `convertOutput`, `convertChangeSetSummary`) could be tested individually.
5. **`convertDescribeResponse`**: No tests for the DescribeChangeSet response conversion.
6. **`checkStackState`**: No tests for the three-way stack state check (non-existent, normal, review-in-progress).
7. **`templateBodyToYaml` with sorted nested keys**: Tests verify top-level key sorting but not nested key sorting (e.g., Parameters children, Resources children).
8. **`quoteYamlString` with strings starting with `!` (YAML tag indicator)**: The `needsQuoting` function includes `!` in the check characters, but there is no explicit test for strings starting with `!`.
9. **`emitCfnYaml` with deeply nested arrays of objects**: Only single-level nesting is tested.

## Positive Observations

1. **Excellent DI pattern for polling**: `pollForCompletionWith` accepting an `IO [CF.StackEvent]` action instead of requiring a `CfnContext` makes the polling engine fully testable without AWS mocking. This is a best-practice pattern.

2. **Consistent operation structure**: All write operations follow the same pattern: build request, send, extract ID, emit definition, poll, collect contents, emit. This makes the codebase predictable and maintainable.

3. **Thorough event dedup**: The polling uses a `Set Text` for event ID tracking, and `watchStack` adds a second dedup layer for pre-existing events. Both layers are well-documented.

4. **Well-documented edge cases**: Comments throughout explain non-obvious decisions (e.g., why `percentEncode` lives in StackOperations, why the first poll batch is empty, why watch-stack returns 0 on timeout).

5. **Good error classification in changeset polling**: `isNonRetryableError` correctly distinguishes permanent errors (NotFound, AccessDenied, ValidationError) from transient ones, preventing infinite retries on terminal conditions.

6. **Clean YAML emitter**: The CFN YAML emitter with context-aware key sorting is well-structured. The weight functions are clear and the recursive emitter handles all JSON value types correctly.

7. **Strong test infrastructure**: `Test.Shared` provides test data builders for all 26 OutputData types, enabling comprehensive integration testing. The polling tests use real `IORef`-based state to simulate multi-cycle poll behavior.

8. **Consistent exit code handling**: Exit code 130 for user cancellation, 0 for success, 1 for failure across all operations. DELETE_COMPLETE correctly treated as failure in create/update, success in delete.

9. **Defensive coding**: `fromMaybe` consistently used for optional AWS fields, `mapMaybe` for filtering invalid conversion results, `catMaybes` for optional capability mapping.

10. **Token management**: `ctxDeriveToken` tracks all derived tokens via IORef, enabling audit/debugging. The primary vs derived token distinction is consistently applied.

## Grade Justification

Starting from 100:

| Deduction | Issue                                                          |
|----------:|:---------------------------------------------------------------|
|        -3 | OPS-01: updateStack missing DELETE_COMPLETE guard              |
|        -3 | OPS-02: OperationCompleteInfo elapsed time from polling start  |
|        -3 | OPS-03: pollChangesetCompletion unbounded on non-error loops   |
|        -2 | OPS-04: Suspicious terminal statuses in create/update lists    |
|        -1 | OPS-05: Duplicate mkEvent in test modules                      |
|        -3 | OPS-11: pollDriftDetection has no timeout/retry mechanism      |

**Final: 85/100**
