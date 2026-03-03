# Code Review R9: CFN Operations & Polling

**Date**: 2026-03-01
**Round**: 9
**Scope**: CFN operations, polling engine, YAML emitter, changeset operations
**Prior reviews**: none (independent review)
**Note**: Architectural items listed in known-deferred list are excluded from this review.

## Grade: 82/100

## Summary

The CFN operations layer is well-structured and competently implemented. The polling engine in `StackOperations.hs` is the strongest piece of code reviewed: clean separation of concerns via `PollConfig` callbacks, proper event deduplication with `Set`, and the testability-via-DI pattern (`pollForCompletionWith`) is excellent. The conversion functions in `DescribeStack.hs` and `Changeset.hs` are straightforward and correct.

The main areas for improvement are: (1) a missing feature in the changeset request builder (`notificationARNs` not forwarded), (2) `createChangeset` never returns `Left` despite its `Either` return type, creating dead code in three callers, (3) several pure conversion functions lack unit tests despite being easily testable, and (4) `formatEvent` in `WatchStack` is dead production code. The YAML emitter in `ConvertStack.hs` is well-crafted with thorough test coverage for its quoting logic.

## Issues Found

### OPS-01: `buildCreateChangeSetRequest` omits `notificationARNs` (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/RequestBuilder.hs:121-136`
**What**: `buildCreateStackRequest` (line 67) and `buildUpdateStackRequest` (line 98) both set `notificationARNs` from `saNotificationArns args`, but `buildCreateChangeSetRequest` does not. The amazonka `CreateChangeSet` type does support `notificationARNs` (confirmed in the generated module). When a user specifies `NotificationARNs` in their stack-args.yaml and creates a changeset, those ARNs are silently dropped.
**Fix**: Add `CCS.notificationARNs = saNotificationArns args` to the `buildCreateChangeSetRequest` record update (around line 133).

### OPS-02: `createChangeset` never returns `Left`, making callers' `Left` branches dead code (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:90-116`
**What**: `createChangeset` has return type `IO (Either Text ChangeSetInfo)` but always returns `Right finalInfo`. If `Amazonka.send` fails, it throws an exception rather than returning `Left`. This creates dead code in three call sites that pattern match on `Left err`:
- `UpdateStack.hs:155` (`Left err -> pure (Left err)`)
- `CreateOrUpdate.hs:99` (`Left err -> pure (Left err)`)
- `CreateOrUpdate.hs:139` (`Left err -> pure (Left err)`)
**Fix**: Either wrap the `Amazonka.send` call in `try` and return `Left` on failure (matching the pattern used in `describeChangesetRaw`), or simplify the return type to `IO ChangeSetInfo` and remove the dead `Left` branches in callers.

### OPS-03: `WatchStack.formatEvent` is dead production code (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/WatchStack.hs:99-106`
**What**: `formatEvent` is exported and tested (4 tests in `WatchStackTest.hs`), but it is never called from any production code. The output pipeline uses `convertEvent`/`convertEventWithDuration` from `DescribeStack.hs` for all event formatting. This appears to be a leftover from an earlier iteration before the output pipeline was wired up.
**Fix**: Remove `formatEvent` from the module (and its tests) if it is genuinely unused, or move it to a utility module if it serves a debugging purpose.

### OPS-04: `buildEventsDisplay` computes list length inefficiently (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs:131-144`
**What**: Line 133 computes `total = length taken + length rest`. Since `(taken, rest) = splitAt numEvents events`, this traverses both sublists, which is equivalent to `length events`. While both are O(n), the current formulation obscures the intent and allocates two thunks. More importantly, `length rest` is O(n - numEvents) and could be avoided entirely since the only use is checking `total > numEvents`, which is equivalent to `not (null rest)`.
**Fix**: Replace `total = length taken + length rest` and `if total > numEvents` with `if not (null rest)`, using `truncTotal = numEvents + length rest` only when building the `TruncationInfo`.

### OPS-05: `pollForCompletionWith` parameter `startTime` shadows outer binding (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs:233-234`
**What**: The inner `go` function takes `startTime` as a parameter (line 233), but it is always called with the same value from line 231. The parameter shadows the `startTime` binding from the enclosing `where` clause. Since `startTime` never changes across recursive calls, it could be captured as a closure variable instead, removing one parameter from the recursive function and eliminating the shadowing.
**Fix**: Remove `startTime` from `go`'s parameter list and let it be captured from the enclosing scope. The recursive call on line 286 already passes the same `startTime` value.

### OPS-06: `describeChangeset` is a trivial delegation to `describeChangesetRaw` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:219-225`
**What**: `describeChangeset ctx stackName csName = describeChangesetRaw ctx stackName csName`. This is a one-line function that provides no additional logic, documentation, or abstraction over `describeChangesetRaw`. It adds an unnecessary layer of indirection.
**Fix**: Either inline `describeChangesetRaw` into `describeChangeset` and remove the `Raw` variant, or export `describeChangesetRaw` directly with the public name.

### OPS-07: `inlineValue` fallback for non-empty collections produces Haskell `show` output (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:278`
**What**: The catch-all case `_ -> T.pack (show val)` would produce Haskell data-constructor syntax like `Object (fromList [...])` for non-empty Object/Array values, rather than valid YAML or JSON inline syntax. While this branch is currently unreachable through the normal `emitValue` code path (which handles non-empty collections before calling `inlineValue`), the function is exported for testing and could be called directly on a non-empty collection.
**Fix**: Either add a comment documenting that this branch is unreachable in normal use, or emit valid JSON inline syntax for the fallback case (e.g., using `Aeson.encode`).

### OPS-08: `convertDescribeResponse` reads `resp.status` without `Maybe` wrapper (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:255`
**What**: `csiStatus = CF.fromChangeSetStatus resp.status` accesses `resp.status` directly. Looking at the amazonka `DescribeChangeSetResponse` type, the `status` field is `ChangeSetStatus` (not `Maybe ChangeSetStatus`), so this is actually correct. This is not a bug, but worth noting the implicit assumption that the API always returns a status.
**Fix**: No action needed. This is not actually a bug -- the amazonka type guarantees the field is present.

## Test Coverage Assessment

### Well-tested pure functions:
- `formatEvent`: 4 tests covering all field combinations (but the function itself is dead code)
- `stackNameFromId`: 3 tests (ARN, plain name, slashes)
- `isStackNotFoundError`: 6 tests (positive, negative, different error types)
- `isNoUpdatesError`: 5 tests (positive, negative, different codes/messages)
- `pollForCompletionWith`: 7 tests (terminal detection, multi-poll, dedup, nested resources, different statuses)
- `percentEncode`: 11 tests (letters, digits, unreserved, unicode, etc.)
- `extractRegionFromArn`: 6 tests (various regions, malformed, empty)
- `buildChangesetConsoleUrl`: 5 tests (URL structure, encoding, regions)
- `buildChangeSetCreationResult`: 10 tests (types, names, changes, console URL)
- `convertChange`/`convertDetail`: 6 + 2 tests
- `generateDashedName`: 3 tests (format, non-empty, variety)
- `calculateEventDurations`: 7 tests (matching pairs, min 1s, missing start, empty, failed, independent, no timestamp)
- `buildConsoleUrl`: 3 tests
- `quoteYamlString`: 28 tests (comprehensive covering all quoting triggers)
- `emitCfnYaml`: 12+ tests (scalars, nesting, arrays, objects in arrays, round-trip)
- `buildStackArgsYaml`: 2 tests (basic, SSM)
- `templateBodyToYaml`: 4 tests (JSON, YAML, sorting, unsorted)
- `parameterizeEnv`/`parameterizeStackName`: 5 tests
- `mapCapability`/`mapCapabilities`: 5 + 3 tests
- `mapParameters`/`mapTags`/`mapOnFailure`: 3 + 3 + 5 tests

### Gaps in test coverage for pure/testable functions:

1. **`convertStack` (DescribeStack.hs:87-123)**: No unit tests. This is a pure function that converts a `CF.Stack` to a `StackDefinition`. It could be tested by constructing a `CF.Stack` value (via `newStack`) and verifying the output fields. Currently only exercised through integration paths.

2. **`convertEvent` (DescribeStack.hs:147-160)**: No unit tests. Pure conversion from `CF.StackEvent` to `StackEvent`. Easily testable with `SE.newStackEvent`.

3. **`convertEventWithDuration` (DescribeStack.hs:196-202)**: Only indirectly tested via `Phase14FixTest.hs`. No direct unit tests for the duration clamping (`max 1`) or the `Nothing` timestamp case.

4. **`convertResource` (StackOperations.hs:307-315)**: No unit tests. Pure conversion function.

5. **`convertOutput` (StackOperations.hs:317-325)**: No unit tests. Returns `Nothing` when `outputKey` is absent -- not tested.

6. **`convertChangeSetSummary` (StackOperations.hs:327-342)**: No unit tests. Returns `Nothing` on missing name/id -- not tested.

7. **`buildEventsDisplay` (DescribeStack.hs:130-144)**: No unit tests. The truncation logic, title formatting, and event wrapping are all pure and testable.

8. **`chooseWeightFn` (ConvertStack.hs:254-264)**: Not directly tested. The sorting behavior is indirectly tested through `templateBodyToYaml` top-level key sorting test, but context-dependent weight selection (Parameters, Resources, Tags, Outputs, IAM, Policies) is not individually verified.

## Positive Observations

1. **Polling engine design**: The `PollConfig` callback pattern in `StackOperations.hs` is clean and extensible. The `pollForCompletionWith` DI pattern enables thorough testing of the polling loop without AWS mocking. The event deduplication via `Set.notMember` is correct and efficient.

2. **Double dedup in `watchStack`**: The second dedup layer in `watchStack` (filtering against `seenIds` from initial events) prevents re-emitting historical events that the polling loop doesn't know about. This is a subtle correctness detail handled well.

3. **YAML emitter**: The custom CFN YAML emitter is well-designed. The weight function system for context-dependent key sorting handles the complex CFN template structure (document-level, parameters, resources, tags, outputs, IAM) correctly. The context propagation through `parentKey`/`currentKey` is subtle but correct.

4. **`quoteYamlString` thoroughness**: The string quoting logic in `ConvertStack.hs` handles a comprehensive set of edge cases: YAML booleans, numbers, null aliases, dash sequences, control characters, dot-prefixed strings, and single-quote prefixes. The test coverage (28 tests) matches this thoroughness.

5. **Consistent exit code pattern**: All operations use the same `Either Text Int` return type convention with consistent exit codes: 0 for success, 1 for failure, 130 for user cancellation.

6. **Clean module boundaries**: The split between `StackOperations` (building blocks), `DescribeStack` (shared helpers), `Context` (terminal statuses), and individual operation modules is well-organized with minimal circular dependencies.

7. **RequestBuilder**: Clean separation of request construction from request execution. The mapping functions (`mapCapabilities`, `mapParameters`, `mapTags`, `mapOnFailure`) are small, focused, and well-tested.

## Grade Justification

Starting from 100:

| Deduction | Issue                                                                          |
|----------:|:-------------------------------------------------------------------------------|
|        -5 | OPS-01: Missing `notificationARNs` in changeset request builder (feature gap)  |
|        -3 | OPS-02: `createChangeset` never returns `Left`, dead code in 3 callers         |
|        -2 | OPS-03: `formatEvent` is dead production code                                  |
|        -1 | OPS-04: `buildEventsDisplay` inefficient length calculation                    |
|        -1 | OPS-05: `startTime` parameter shadowing in `go`                               |
|        -1 | OPS-06: Trivial `describeChangeset` wrapper                                   |
|        -1 | OPS-07: `inlineValue` fallback produces invalid output for non-empty colls     |
|        -4 | Test gaps: 7 pure conversion functions with no direct unit tests               |

**Final: 82/100**

The code is solid production-quality Haskell with good architecture. The main deductions are for the `notificationARNs` feature gap (a real omission that affects users), the misleading `Either` return type that creates dead code, and the untested pure functions that could easily have unit tests. None of the issues are crash-inducing or data-corrupting bugs.
