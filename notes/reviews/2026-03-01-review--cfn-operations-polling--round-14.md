# Code Review R14: CFN Operations & Polling

**Date**: 2026-03-01
**Round**: 14
**Scope**: CFN operations, polling engine, YAML emitter, changeset operations
**Prior reviews**: none (independent review)
**Note**: Architectural items listed in known-deferred list are excluded from this review.

## Grade: 90/100
## Letter Grade: A-
## Trust Assessment

This codebase reflects a careful, professional porting effort with strong engineering discipline. The code demonstrates consistent patterns across all 12 production modules: explicit type signatures, qualified imports, proper error handling for AWS operations, and a well-designed dependency injection pattern in `pollForCompletionWith` that enables thorough unit testing of the polling loop. The test suite is focused on pure functions and uses mock-based testing for IO operations where appropriate. The 811-test count with 49/49 error snapshot matches and 37/37 render snapshots, combined with evidence of 40+ iterative sessions with bug fixes, indicates a mature review-fix cycle rather than a rush job. The known-deferred list itself demonstrates awareness of intentional trade-offs rather than blind spots.

## Summary

The CFN operations and polling engine is well-structured, correct, and thoroughly tested for its pure logic. The polling loop design is particularly strong -- the dependency injection via `pollForCompletionWith` enables comprehensive testing without AWS mocking. The YAML emitter handles a complex set of quoting rules correctly. I found a small number of issues, none of which are critical bugs in normal operation. The main findings are: (1) a potential space leak in the polling loop's event set growth, (2) a race condition in `collectStackContents` that could surface under unusual timing, (3) unused `ChangeSetInfo` fields that are always empty, and (4) some minor test coverage gaps for edge cases in pure functions.

## Issues Found

### OPS-01: Unbounded event set growth in polling loop (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs:287-289`
**What**: The `newSet` grows monotonically by accumulating all seen event IDs. For very long-running operations (hours), this set could contain thousands of event IDs that are never needed again, since the AWS API returns events in most-recent-first order and old events will never reappear. The bang pattern on `newSet` prevents thunk buildup but not the underlying set size growth.
**Fix**: Not critical -- CFN operations rarely produce more than a few hundred events. A theoretical improvement would be to cap the set size or use a sliding window, but the practical impact is negligible for real-world CloudFormation stacks.

### OPS-02: No exception handling in `collectStackContents` API calls (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs:121-176`
**What**: `collectStackContents` makes four separate API calls (DescribeStackResources, DescribeStacks, ListChangeSets, ListExports) without any exception handling. If the stack is deleted or permissions change between calls, an unhandled Amazonka exception will propagate. The `getStack` call on line 129 already handles the `ValidationError` case, but the `DescribeStackResources` call on line 125 does not.
**Fix**: Consider wrapping `DescribeStackResources` in a `try` block similar to `getStack`, or document that the caller is expected to handle exceptions. In practice, this is an unlikely race condition and all callers are in IO where exceptions propagate to the top-level handler in Main.hs.

### OPS-03: `csiChanges` is always empty for `convertChangeSetSummary` (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs:348`
**What**: `convertChangeSetSummary` always sets `csiChanges = []` because `ChangeSetSummary` from the ListChangeSets API does not include change details. The changes are only available via DescribeChangeSet. This means the `ChangeSetInfo` objects in `StackContents.scPendingChangesets` always have empty change lists. This is correct behavior (the data isn't available from the API), but the shared type makes it non-obvious that changesets from `collectStackContents` will never have changes populated.
**Fix**: Consider a documentation comment on the `csiChanges` field or on `convertChangeSetSummary` noting that changes are only populated by `describeChangeset`.

### OPS-04: `convertStack` creates `sdStackPolicy = Nothing` always (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs:119`
**What**: `convertStack` always sets `sdStackPolicy = Nothing`, even though `GetStackPolicy` is available as a separate API call. The `ConvertStack` module does fetch the stack policy (line 466), but `convertStack` (which is used by describe-stack, watch-stack, delete-stack, etc.) never does. This means the stack policy is never shown in the interactive output for describe-stack.
**Fix**: If the Rust implementation shows the stack policy in describe-stack output, this is a feature gap. If not, this is just a documentation note. Given the known-deferred list doesn't mention it, this is likely by design.

### OPS-05: `buildEventsDisplay` title is hardcoded regardless of context (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs:139`
**What**: The title `"Previous Stack Events (max " <> T.pack (show numEvents) <> "):"` is always used, even when the caller is `describeStack` where it makes perfect sense, but also when called from `deleteStack` or `watchStack`. The title implies these are "previous" events, which is correct in all current calling contexts.
**Fix**: No fix needed -- the title is accurate in all contexts. Just noting the coupling.

### OPS-06: `executeChangeset` success states combine both create and update lists (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:219`
**What**: `let successStates = createSuccessStates ++ updateSuccessStates` produces `["CREATE_COMPLETE", "UPDATE_COMPLETE"]`. This is correct -- a changeset execution could result in either status depending on whether it was a CREATE or UPDATE changeset. The approach handles both cases without needing to thread the changeset type through.
**Fix**: No fix needed. This is correct. Noting it because it could look like a bug at first glance.

### OPS-07: `pollChangesetCompletion` initial delay before first check (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:140`
**What**: The `go` function calls `threadDelay (2 * 1000000)` at the top of each iteration, including the first one. This means there's always a 2-second delay before the first DescribeChangeSet call, even though the changeset might already be in a terminal state by the time polling starts (especially for simple templates where changeset creation completes in under 2 seconds).
**Fix**: Move the `threadDelay` to the end of the loop (before the recursive `go` call) to check status immediately on the first iteration. This is a minor UX improvement (saves ~2 seconds), not a correctness issue.

### OPS-08: `emitItem` first-key handling for sorted arrays of objects (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:247-262`
**What**: In `emitItem`, when emitting an array of objects, the first key-value pair gets special `- key: value` treatment while subsequent pairs get standard `emitPair` indentation at `indent + 2`. The first key's nested children use `indent + 4` (line 253). This YAML formatting is correct -- the first key shares the `- ` prefix line. The code is subtle but handles nested objects within array items properly.
**Fix**: No fix needed. Correct behavior.

### OPS-09: `processStack` deeply nested function with many parameters (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:458-528`
**What**: `processStack` takes 9 parameters and performs multiple sequential operations (get policy, create directory, write files). The function is 70 lines long with deeply nested logic. While each step is clear, the parameter list makes the function hard to refactor.
**Fix**: Consider grouping related parameters into a record (e.g., `ConvertOptions`). This is a code organization improvement, not a correctness issue.

### OPS-10: `deleteStack` fetches events and contents before confirmation (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DeleteStack.hs:78-81`
**What**: `deleteStack` fetches events and stack contents before asking the user for confirmation. The comment on line 77 explains this matches Rust behavior (showing info to help the user decide). This is intentional, but it means two additional API calls even if the user will decline. The cost is negligible.
**Fix**: No fix needed -- the design is documented and matches the source implementation.

## Test Coverage Assessment

### Well-tested pure functions:
- `stackNameFromId` -- ARN parsing, plain name, multiple slashes
- `pollForCompletionWith` -- terminal status, multi-poll, dedup callbacks, nested resource filtering, DELETE_COMPLETE, UPDATE_ROLLBACK_COMPLETE, overall timeout, inactivity timeout (8 test cases)
- `isNoUpdatesError` / `isStackNotFoundError` -- positive matches, wrong code, wrong message, no message, non-ServiceError
- `calculateEventDurations` -- matching pairs, floor clamp, no match, empty, FAILED events, multiple resources, no timestamps (7 test cases)
- `convertEventWithDuration` -- sub-second rounding, exact durations
- `convertEvent` -- all fields, missing optional fields, timestamp extraction
- `convertStack` -- all fields, minimal stack, StackSetName from tags
- `buildEventsDisplay` -- truncation, no truncation, title format
- `convertResource`, `convertOutput`, `convertChangeSetSummary` -- all fields, missing required fields, defaults
- `percentEncode` -- empty, letters, digits, unreserved, colon, slash, ARN, space, hash, Unicode
- `extractRegionFromArn` -- various ARN formats, fallback
- `buildChangesetConsoleUrl` / `buildConsoleUrl` -- URL structure, encoding, regions
- `buildChangeSetCreationResult` -- UPDATE/CREATE types, all fields, hasChanges true/false, console URL
- `convertChange` / `convertDetail` -- missing resourceChange, missing fields, valid change, empty detail
- `generateDashedName` -- format, non-empty, variety
- `formatAmazonkaError` / `isNonRetryableError` -- service errors, non-service errors
- `mapCapability`, `mapCapabilities`, `mapParameters`, `mapTags`, `mapOnFailure`, `serializeStackPolicy` -- comprehensive parameter mapping
- `parameterizeEnv`, `parameterizeStackName` -- all environments, trailing digits, project replacement
- `templateBodyToYaml` -- JSON->YAML, YAML passthrough, key sorting, unsorted, invalid input
- `buildStackArgsYaml` -- basic, SSM params
- `emitCfnYaml` -- scalars, nested objects, arrays, empty collections, objects in arrays, round-trips
- `quoteYamlString` -- plain, empty, booleans, null, yes/no, colon, spaces, quotes, numbers, dash-seq, tilde, dot-prefix, quote-prefix, control chars (30+ test cases)
- `buildCliArguments`, `getStrMapValidated`, credential display names -- Phase 14 fixes

### Gaps in test coverage:
- **`pollForCompletionWith` with `pcWaitForStatusChange = True`**: The watch-stack test for this is only tested at the integration level (the test harness sets it, but no unit test verifies the guard logic in isolation -- e.g., what happens when terminal status is reached but `hasSeenNewEvents` is still `False`). The existing inactivity timeout test partially covers this but doesn't test the terminal status + wait-for-change interaction specifically.
- **`pollChangesetCompletion`**: No unit tests. This function has retry logic, error counting, max iterations cap, and terminal status detection. These are all pure-ish logic (depends on IO for the API call) but could be tested with a mock pattern similar to `pollForCompletionWith`.
- **`checkStackState` / `findPendingChangeset`**: No unit tests. These detect REVIEW_IN_PROGRESS and find pending changesets -- important for the create-changeset flow.
- **`convertDescribeResponse`**: No unit test for converting a DescribeChangeSetResponse. The `convertChange` and `convertDetail` functions are tested individually, but the orchestrating conversion function is not.
- **`needsDriftCheck` / `checkTimestampStale`**: No unit tests. These are pure-ish functions that compare timestamps and check drift status -- could be unit tested.
- **`chooseWeightFn`**: Not directly tested. The sort weight functions are exercised indirectly via `templateBodyToYaml` sort tests, but the parent/current key dispatch logic in `chooseWeightFn` is not directly verified.
- **`quoteYamlKey`**: Not directly tested (only through `emitCfnYaml` integration). Keys with colons (like `Fn::Sub`) should be tested.

## Positive Observations

1. **Dependency injection in `pollForCompletionWith`**: This is an excellent design. By accepting the event fetcher as a parameter, the entire polling loop -- including dedup, timeout, inactivity, and terminal status detection -- becomes testable without AWS mocking. The 8 test cases for this function are thorough and cover real scenarios.

2. **Consistent error handling pattern across operations**: All write operations (create, update, delete, changeset) follow the same pattern: send request -> get stack ID -> emit definition -> poll -> check result -> emit contents -> return exit code. This consistency makes the code predictable and auditable.

3. **Defensive event filtering**: The `isStackEvent` function uses a dual check (`logicalResourceId == stackName AND resourceType == AWS::CloudFormation::Stack`) to prevent nested stack events from being mistaken for the top-level stack status. This is documented and prevents a subtle class of bugs.

4. **YAML quoting completeness**: The `quoteYamlString` function handles an impressive range of YAML edge cases -- number-like strings, YAML 1.1 booleans (`yes`/`no`), tilde (null alias), dot-prefixed floats, dash-sequence indicators, control characters requiring double-quoting, and single-quote prefix strings. The 30+ test cases for this function are a strong defense against YAML injection.

5. **Changeset polling resilience**: The `pollChangesetCompletion` function has three layers of protection: per-iteration max (300 = 10 minutes), transient error retry budget (30 retries), and non-retryable error fast-fail. This prevents both infinite hangs and premature failures on transient AWS errors.

6. **Clean separation of pure and IO logic**: Pure conversion functions (`convertEvent`, `convertStack`, `convertResource`, `convertOutput`, `convertChange`, `convertDetail`) are separated from IO operations and independently tested. This makes the code easy to verify and maintain.

7. **Thorough test helper infrastructure**: The `Test.Shared` module provides 26 test data builders covering all `OutputData` variants, plus shared helpers like `mkEvent`. This infrastructure reduces test boilerplate and ensures consistency.

8. **Documentation of non-obvious design decisions**: The known-deferred list, inline comments explaining Rust compatibility, and the `allTerminalStatuses` documentation (explaining why UPDATE_FAILED is not terminal, why DELETE_SKIPPED is included) demonstrate careful thought about the porting fidelity.

## Grade Justification

Starting from 100:

| Deduction | Issue                                                                     |
|----------:|:--------------------------------------------------------------------------|
|        -2 | OPS-01: Unbounded event set growth (theoretical, not practical)           |
|        -2 | OPS-02: No exception handling in collectStackContents API calls           |
|        -2 | OPS-07: Initial 2s delay in pollChangesetCompletion before first check    |
|        -1 | OPS-03: Always-empty csiChanges without documentation                     |
|        -1 | OPS-04: sdStackPolicy always Nothing in convertStack                      |
|        -1 | OPS-09: processStack has 9 parameters (code organization)                 |
|        -1 | Test gap: pollChangesetCompletion has no unit tests for retry/cap logic   |

**Final: 90/100**
