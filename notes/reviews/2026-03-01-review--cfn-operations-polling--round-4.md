# Code Review R4: CFN Operations & Polling

**Date**: 2026-03-01
**Round**: 4
**Scope**: CFN operations, polling engine, YAML emitter, changeset operations
**Prior reviews**: none (independent review)

## Grade: 80/100

## Summary

The CFN operations layer is well-structured with clean separation of concerns: a shared `StackOperations` module provides building blocks (event fetching, polling, content collection), individual operation modules (`CreateStack`, `UpdateStack`, `DeleteStack`, `WatchStack`, `Changeset`, `ConvertStack`) implement the command-specific flows, and `RequestBuilder` handles API request construction. The polling engine is testable via dependency injection (`pollForCompletionWith`), and the output pipeline uses a clean `OutputData -> IO ()` emitter pattern.

However, several issues warrant attention: three API calls lack pagination (could silently truncate results in production), the polling engine has an event deduplication strategy that relies on rebuilding the full event set every cycle (discarding history), and `ConvertStack` writes directly to stderr/filesystem bypassing the output pipeline. The test suite is solid on pure functions and polling mechanics but doesn't test any of the IO-heavy operation entry points, even with mocked AWS calls. Type safety is generally good but several Text-typed fields (statuses, regions, actions) could benefit from proper sum types.

## Issues Found

### OPS-01: No pagination for ListExports (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:132
**What**: `collectStackContents` calls `Amazonka.send (cfnEnv ctx) LE.newListExports` which returns at most 100 exports per page. The `nextToken` in the response is never checked. For AWS accounts with >100 exports, this silently drops exports, causing the stack's exports to appear incomplete or empty.
**Fix**: Use `Amazonka.paginate` or implement manual pagination loop checking `resp.nextToken`. Alternatively, use the `runConduit` pagination helpers from amazonka.

### OPS-02: No pagination for ListChangeSets (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:127-129
**What**: `collectStackContents` calls `LCS.newListChangeSets sName` without handling pagination. Stacks with many changesets (AWS retains history) will have results truncated silently.
**Fix**: Same as OPS-01 -- paginate the ListChangeSets call.

### OPS-03: No pagination for DescribeStackEvents (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:93-98
**What**: `fetchStackEvents` makes a single `send` call which returns at most one page of events. For long-lived stacks with many events, this means `buildEventsDisplay` (used by describe-stack, delete-stack, watch-stack) may not get all historical events. While the polling loop handles this gracefully (it only needs recent events), the `buildEventsDisplay` path that shows "Previous Stack Events (max N)" may return fewer events than exist, making the truncation info misleading. For polling this is less critical since the loop is interested in the latest events (most recent page), but for describe-stack showing historical events, it matters.
**Fix**: For describe-stack and pre-operation event display, paginate until enough events are collected. For the polling loop, the current single-page approach is acceptable.

### OPS-04: Event set rebuilt from scratch every poll cycle (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:266
**What**: Each poll iteration calls `Set.fromList (map (.eventId) events)` on all returned events, replacing the entire set. This means if a previous poll cycle saw event IDs that are no longer in the current API response (due to pagination -- events only returned by page 1 on an earlier call might not appear now), those events could be re-reported as "new." In practice, CloudFormation events are append-only and returned most-recent-first, so this is unlikely to cause issues, but it's conceptually fragile: the set should be accumulated, not replaced.
**Fix**: Change to `Set.union lastEventSet (Set.fromList (map (.eventId) events))` to grow the set monotonically.

### OPS-05: `collectStackContents` exports filter compares `Maybe Text == Maybe Text` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:144
**What**: The expression `e.exportingStackId == s.stackId` compares two `Maybe Text` values. If `s.stackId` is `Nothing` (theoretically possible for a stack returned by DescribeStacks), this would match any export with `exportingStackId = Nothing`, which is incorrect. In practice, `s.stackId` is always `Just arn`, but the code should be defensive.
**Fix**: Use a pattern match or `fromMaybe` comparison that defaults to a non-matching sentinel on `Nothing`.

### OPS-06: `ConvertStack` bypasses output pipeline (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`:414,419,427,457 and 507,515-516
**What**: `convertStackToIidy` writes directly to `stderr` via `hPutStrLn stderr` and directly to the filesystem via `TIO.writeFile`. This bypasses the output pipeline (`emit` pattern) used by all other operations, making it impossible to capture or redirect output in JSON mode, and inconsistent with the architecture.
**Fix**: Accept an `emit :: OutputData -> IO ()` parameter and define an `OdConvertProgress` or similar `OutputData` variant for progress messages. File writing is fine to keep as direct IO since that's the operation's purpose.

### OPS-07: `convertStack` in DescribeStack uses `coerce` for time conversion (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs`:114-115
**What**: `coerce s.creationTime :: UTCTime` and `coerce t :: UTCTime` use `Data.Coerce.coerce` to extract the time from amazonka's `Time` newtype. While this works, it creates a tight coupling to amazonka's internal representation. If amazonka ever changes the `Time` newtype (unlikely but possible), this would silently break.
**Fix**: Use `.fromTime` (the record accessor) instead, which is the idiomatic amazonka 2.x approach. The `Changeset` module already uses `.fromTime` at line 261/315.

### OPS-08: `buildEventsDisplay` computes `length events` for all events (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs`:131
**What**: `length events` traverses the entire event list to compute the total count, even though only `numEvents` events are actually used. For stacks with thousands of events (if pagination were added per OPS-03), this would be O(n) work just for the truncation info.
**Fix**: This is minor given the current lack of pagination. If pagination is added, consider computing the count more efficiently or using the API's reported total.

### OPS-09: `updateStack` non-"NoUpdates" errors are stringified with `show` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/UpdateStack.hs`:97
**What**: When an AWS error that isn't "No updates are to be performed" occurs, the code returns `Left (T.pack (show awsErr))`. The `show` instance for `Amazonka.Error` produces a Haskell data-constructor representation, not a user-friendly message. Meanwhile, the `isNoUpdatesError` path re-throws the error for the top-level handler. This inconsistency means some AWS errors get ugly `show`-formatted messages.
**Fix**: Either re-throw all AWS errors consistently (as is done for `isNoUpdatesError`) and let the top-level handler format them, or extract the error message properly from `Amazonka.ServiceError`.

### OPS-10: Dead code: `UpdateResult` type is unused (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Types.hs`:72-75
**What**: `UpdateResult` (with constructors `UpdateNoChanges` and `UpdateStackId`) is defined and exported but never imported or used anywhere in the codebase. `StackChangeType` is used (via `StackChangeDetails` in `Output/Types.hs` and both renderers), but `UpdateResult` is dead code.
**Fix**: Remove `UpdateResult` from `Iidy.Cfn.Types` to reduce confusion.

### OPS-11: `extractRegionFromArn` falls back to `us-east-1` silently (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`:345
**What**: When the ARN cannot be parsed (malformed or empty), the function returns `"us-east-1"` as a default. This means console URLs in changeset results would point to the wrong region without any indication of the error.
**Fix**: Consider returning `Maybe Text` or logging a warning. However, this matches Rust behavior and the ARN should always be well-formed when coming from AWS, so this is low priority.

### OPS-12: `pollChangesetCompletion` has a hardcoded retry ceiling without backoff (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`:121-150
**What**: The changeset polling retries transient errors up to 30 times at 2-second intervals (60 seconds max). There is no exponential backoff, and the 2-second fixed interval might be too aggressive for rate-limited accounts. Also, the error count resets to 0 on any success, meaning a pattern of alternating success/failure could poll indefinitely.
**Fix**: Consider exponential backoff for errors. The error-count-reset-on-success behavior is actually correct (it ensures transient blips don't count toward the limit), but the lack of backoff is notable.

### OPS-13: `quoteYamlString` does not handle double-quote character (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`:282
**What**: The `needsQuoting` function checks for many special characters (`:{}&*?|>!%@\`#,[]`) but does not include the double-quote character (`"`). A YAML value containing `"` does not strictly need single-quoting (YAML allows unquoted strings with `"` in flow context), but the behavior could produce surprising results in edge cases where the string starts with `"`.
**Fix**: Add `"` to the special character set, or verify this matches Rust behavior.

### OPS-14: `isStackEvent` filter in polling may miss events for renamed stacks (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`:268-271
**What**: `isStackEvent` checks if `logicalResourceId == Just (stackNameFromId sId)` OR `resourceType == "AWS::CloudFormation::Stack"`. The second condition is overly broad -- it would match events from nested stacks (child stacks of type `AWS::CloudFormation::Stack`) that happen to appear in the event stream. This could cause premature polling termination if a nested stack reaches a terminal status before the parent.
**Fix**: The `OR` should be `AND` for nested stacks, or the filter should additionally verify that the event's `stackId` matches the target stack ID.

### OPS-15: `buildStackArgsYaml` environment tag lookup is inconsistent (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`:434-436
**What**: The code looks up the environment from tags using `lookup "environment"` first, then falls back to `lookup "Environment"`. But `formatTag` (line 346) only matches lowercase `"environment"` and capitalized `"Environment"` for parameterization. If a user has a tag named e.g. `"ENV"`, it won't be detected. This is a minor consistency concern rather than a bug.
**Fix**: Document the expected tag name convention, or normalize tag keys to lowercase before comparison.
**Resolution**: FIXED — changed to case-insensitive lookup via `T.toLower`. CF tags have no case convention.

### OPS-16: `mapCapabilities` silently drops invalid capabilities (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/RequestBuilder.hs`:150-153
**What**: `mapCapabilities` uses `catMaybes` to filter out capabilities that don't match any known enum value. Invalid capability strings are silently dropped with no warning. A user who typos a capability name (e.g., `"CAPABILITY_NAMED_IAH"`) would get no feedback.
**Fix**: Emit a warning for unrecognized capability strings, or fail with a validation error during stack-args parsing.

### OPS-17: `deleteStack` return type inconsistency (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DeleteStack.hs`:55
**What**: The return type is `IO (Either Text Int)` where `Left` represents an error message and `Right` an exit code. However, `deleteStack` never returns `Left` -- it either returns `Right 0` (success/absent), `Right 130` (user cancelled), or `Right 1` (failure). The `Left` variant is unreachable code. Compare with `updateStack` which can return `Left` for non-NoUpdates AWS errors.
**Fix**: Either simplify the return type to `IO Int` or document when `Left` would be returned. This is a consistency issue across all operations -- some use `Left` for errors, some don't.

## Test Coverage Assessment

**Well-tested areas:**
- Polling engine mechanics: terminal status detection, multi-poll cycling, new-event-only callbacks, non-stack-resource filtering, DELETE_COMPLETE/UPDATE_ROLLBACK_COMPLETE detection (7 tests)
- Event formatting: all-fields, missing-fields, partial-fields edge cases (4 tests)
- `stackNameFromId`: ARN format, plain name, multi-slash (3 tests)
- Changeset type conversion: `convertChange` null cases, `convertDetail` edge cases (7 tests)
- `generateDashedName`: format validation, non-emptiness, randomness (3 tests)
- Changeset helpers: `percentEncode` (11 tests), `extractRegionFromArn` (6 tests), `buildChangesetConsoleUrl` (5 tests), `buildChangeSetCreationResult` (10 tests)
- YAML emitter: comprehensive coverage of `inlineValue`, `quoteYamlString`, `emitCfnYaml` structure, `templateBodyToYaml` round-trips (25+ tests)
- RequestBuilder mapping functions: capabilities, parameters, tags, onFailure (16 tests)
- ConvertStack pure helpers: `parameterizeEnv`, `parameterizeStackName`, `buildStackArgsYaml` (7 tests)
- Integration: all 26 OutputData variants pass through both renderers, operation-specific sequences validated (14 tests)

**Gaps in test coverage:**
1. **No polling timeout tests**: `PollTimeout` and `PollInactivityTimeout` return values are never tested. The polling engine claims to support these but there are no tests verifying the timeout logic fires correctly.
2. **No `pcWaitForStatusChange` tests**: The watch-stack-specific flag that delays terminal status checking until new events are seen is untested in the polling tests.
3. **`calculateEventDurations` untested**: The duration calculation logic (matching IN_PROGRESS to COMPLETE/FAILED pairs) has no direct tests despite being non-trivial.
4. **`convertEventWithDuration` untested**: The live event duration calculation is not tested.
5. **`mkStandardPollConfig` untested**: The callback wiring that converts raw CF events to `OdNewStackEvents` is not tested.
6. **`isNoUpdatesError` untested**: The error detection helper in UpdateStack has no test.
7. **`isStackNotFoundError` untested**: The error detection helper in StackOperations has no test.
8. **`buildConsoleUrl` untested**: The stack console URL construction is not tested.
9. **`checkStackState` untested**: The stack state detection for changeset flows (StackDoesNotExist/StackNormal/StackReviewInProgress) has no test.
10. **`confirmChangesetExecution` untested**: No test for the confirmation wrapper.
11. **No `emitCfnYaml` sort-order tests for nested contexts**: The `chooseWeightFn` dispatch (Parameters, Resources, Tags, Outputs, etc.) is not tested directly -- only top-level sort order is verified.

## Positive Observations

1. **Clean architecture**: The separation between `StackOperations` (shared primitives), individual operation modules, and `RequestBuilder` is well-thought-out. Each module has a clear responsibility and minimal coupling.

2. **Testable polling via DI**: The `pollForCompletionWith` function accepts an `IO [CF.StackEvent]` action, enabling pure-ish testing without AWS mocks. This is a textbook example of making IO code testable.

3. **Consistent output pipeline**: All operations use the `emit :: OutputData -> IO ()` pattern for output, enabling both interactive and JSON rendering. The `OutputData` sum type is comprehensive (26 variants) and well-typed.

4. **Comprehensive `OutputData` types**: The types in `Output/Types.hs` are thorough and use strict fields throughout (`!` annotations). Every field is named with a consistent prefix convention (`sd` for StackDefinition, `se` for StackEvent, etc.).

5. **Good error handling patterns**: The `isStackNotFoundError` and `isNoUpdatesError` helpers properly parse AWS errors rather than relying on error codes that might change. The `try`/`catch` usage is appropriate throughout.

6. **`percentEncode` correctness**: The URL encoding function correctly handles Unicode by UTF-8 encoding first, and correctly identifies RFC 3986 unreserved characters. The test suite for this function is thorough.

7. **YAML emitter is well-designed**: The CFN-specific key sorting with context-aware weight functions (`chooseWeightFn`) is a clever approach that produces natural CloudFormation YAML output. The emitter handles edge cases (empty objects/arrays, nested structures, array-of-objects) correctly.

8. **Delete-stack uses stack ARN for polling**: The code correctly fetches the stack ID/ARN before sending the delete request, ensuring polling continues to work after the stack name becomes invalid (since CloudFormation requires the ARN to describe a deleted stack's events).

9. **Strong test infrastructure**: The shared test data builders (`Test.Shared`) and the integration test framework that feeds all 26 variants through both renderers is excellent for catching regressions.

10. **Clear documentation comments**: Every module has a header comment explaining its purpose and relationship to the operation flow. Step-by-step comments in operation functions make the control flow readable.

## Grade Justification

Starting at 100:

| Deduction | Issue                                              | Points |
|-----------|---------------------------------------------------|--------|
| OPS-01    | No ListExports pagination (silent data loss)       |     -4 |
| OPS-02    | No ListChangeSets pagination (silent data loss)    |     -3 |
| OPS-03    | No DescribeStackEvents pagination                  |     -3 |
| OPS-04    | Event set rebuilt vs accumulated in polling         |     -1 |
| OPS-06    | ConvertStack bypasses output pipeline              |     -2 |
| OPS-09    | Ugly `show`-formatted AWS error messages           |     -1 |
| OPS-14    | `isStackEvent` too broad for nested stacks         |     -2 |
| Coverage  | No timeout/inactivity polling tests                |     -2 |
| Coverage  | `calculateEventDurations` untested                 |     -1 |
| Coverage  | `isNoUpdatesError`/`isStackNotFoundError` untested |     -1 |

**Final: 80/100**

The code is production-quality in terms of structure, type safety, and the core polling/operation logic. The main concerns are the missing pagination (which could cause real data loss in larger AWS accounts) and the `isStackEvent` filter potentially causing incorrect behavior with nested stacks. The test coverage is good for pure functions but leaves some IO-adjacent logic untested. Overall this is solid, well-organized code that would benefit from pagination support and a few targeted test additions.
