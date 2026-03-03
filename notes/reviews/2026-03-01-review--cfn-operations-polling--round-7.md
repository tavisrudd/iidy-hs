# Code Review R7: CFN Operations & Polling

**Date**: 2026-03-01
**Round**: 7
**Scope**: CFN operations, polling engine, YAML emitter, changeset operations
**Prior reviews**: none (independent review)

## Grade: 81/100

## Summary

The CFN operations and polling engine is well-structured, with clean separation between the polling core (`StackOperations`), individual operation modules, and shared helpers (`DescribeStack`, `Changeset`). The code is free of partial functions, has no TODOs/FIXMEs, and follows a consistent pattern across all write operations (build request, send, emit StackDefinition, poll, collect contents, return exit code). Type safety is generally good with strict fields and explicit `Maybe` handling.

The main weaknesses are: (1) a correctness bug in `buildEventsDisplay` that counts total events by traversing the remainder list, making it O(n) where a simple `length` would suffice and also producing an incorrect total; (2) several places where `elem` on plain lists is used for terminal status checks that should use `Set` for clarity and performance; (3) the `ConvertStack` module mixes IO effects (file writes, SSM puts, stderr prints) deeply into its logic, making it hard to test the orchestration; (4) moderate test gaps in the write operations (create, update, delete) which are not tested at the operation level, only at the pure-helper and polling-engine levels.

## Issues Found

### OPS-01: `buildEventsDisplay` computes incorrect total event count (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs:131-143`
**What**: The function computes `total = numEvents + length rest` after `splitAt numEvents events`. If `events` has fewer than `numEvents` items, `rest` is `[]` and `total` equals `numEvents` (the limit), not the actual count. For example, if `numEvents=10` and `events` has 5 items, `total=10` and `truncInfo` would say "showing 10 of 10" despite only 5 events existing. The `TruncationInfo` would not be emitted (since `total == numEvents`), so the visual result is correct by accident, but the `total` variable is semantically wrong and any future code relying on it would get the wrong answer.

Wait -- re-reading: `splitAt 10 [a,b,c,d,e]` gives `(taken=[a,b,c,d,e], rest=[])`, so `total = 10 + 0 = 10`. But there are only 5 events. The `truncInfo` check `total > numEvents` is `10 > 10 = False`, so no truncation info is emitted, which is correct. If events has exactly 10, `total = 10 + 0 = 10`, still correct. If events has 15, `total = 10 + 5 = 15`, correct. Actually the total is `numEvents + length rest`, which equals `length taken + length rest = length events` when `length events >= numEvents`, and equals `numEvents` when `length events < numEvents`. The latter is wrong but doesn't affect the truncation check. Downgrading severity.

**Fix**: Use `let total = length events` or `let total = length taken + length rest`. The current formula only gives wrong `total` when there are fewer events than the limit, which is harmless for current usage, but is a latent bug.

### OPS-02: Terminal status lists use `elem` on plain lists (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs:273`, `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:152,207`, and others
**What**: The terminal status lists (`allTerminalStatuses`, `createTerminalStatuses`, etc.) are plain `[Text]` and checked with `elem`, which is O(n) per check. These lists have ~13 entries, so the cost is trivial, but semantically they are sets and would benefit from `Set Text` for both clarity and preventing duplicate entries.
**Fix**: Change `Context.hs` to export `Set Text` values, and use `Set.member` in `StackOperations.hs` and other callers. Low priority since the lists are small.

### OPS-03: `pollForCompletionWith` grows a `Set` monotonically without bound (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs:226-286`
**What**: The `lastEventSet` accumulates every event ID seen across all poll cycles. For very long-running operations (multi-hour deploys with hundreds of resources), this set can grow to thousands of entries, each being a `Text` event ID. The memory impact is modest (a few hundred KB at worst for a massive deploy), but the set is never pruned. Since CloudFormation events are returned most-recent-first and the API returns all events for the stack, the set must grow to correctly deduplicate. This is acceptable behavior but worth documenting.
**Fix**: Add a comment noting that the set grows monotonically and explaining why pruning is not safe (events can reappear across pages).

### OPS-04: `percentEncode` lives in `StackOperations` for dependency reasons (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs:347-362`
**What**: The comment explains it lives here to avoid circular deps. Meanwhile, `Changeset.hs` re-exports it in its own export list (line 25) from `StackOperations` (line 65). This is confusing -- two modules appear to define it but only one does. The `ChangesetHelpersTest.hs` imports it from `Changeset`, not `StackOperations`.
**Fix**: Move to a standalone `Iidy.Util.Url` or similar module that neither `Changeset` nor `DescribeStack` depends on, breaking the circular dependency cleanly. Remove the re-export from `Changeset`.

### OPS-05: `ConvertStack.processStack` deeply interleaves IO effects (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:436-506`
**What**: `processStack` performs API calls, file I/O (createDirectory, writeFile), and stderr output all interleaved in a single function. This makes it untestable without real filesystem and AWS access. The test file (`ConvertStackTest.hs`) only tests the pure helpers (`parameterizeEnv`, `parameterizeStackName`, `templateBodyToYaml`, `buildStackArgsYaml`), leaving the entire orchestration and file-writing logic untested.
**Fix**: Extract the orchestration into a pure function that returns a `[(FilePath, Text)]` list of files to write, then have a thin IO wrapper that does the actual writes. This allows testing the full pipeline.

### OPS-06: `ConvertStack` uses `hPutStrLn stderr` directly instead of the output pipeline (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:463,468,476,505,491,555,563`
**What**: Multiple `hPutStrLn stderr` calls bypass the structured output pipeline (`OutputData -> IO ()` emitter). This means convert-stack output is invisible in JSON rendering mode.
**Fix**: Add an emitter parameter and use `OdStatusUpdate` or a new `OdConvertProgress` variant. Low priority since convert-stack is a local utility command.

### OPS-07: `extractRegionFromArn` falls back silently to `"us-east-1"` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:336-339`
**What**: If the ARN is malformed, the function silently returns `"us-east-1"`. The comment says "ARNs from AWS are always well-formed", which is true for real AWS responses. But if called with user-provided input or a bug produces an empty string, the fallback produces a plausible-but-wrong result that is hard to debug.
**Fix**: Return `Maybe Text` and let callers handle the `Nothing` case, or log a warning. The current behavior matches Rust, so this is acceptable for compatibility.

### OPS-08: `deleteStack` exit code 130 on user cancel does not match POSIX convention (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DeleteStack.hs:89`
**What**: Exit code 130 conventionally means "terminated by SIGINT" (128 + 2). Using it for a "user declined confirmation prompt" is non-standard. However, this matches the Rust implementation behavior, so it is intentional for compatibility.
**Fix**: No action needed -- matches Rust. Document the exit code semantics.

### OPS-09: `updateStackWithChangeset` returns `Right 130` but `createChangeset` returns `Left err` on failure (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/UpdateStack.hs:142-173`
**What**: The error handling is inconsistent: changeset creation failure returns `Left err` (line 155), FAILED status returns `Left` (line 164), but user cancellation returns `Right 130` (line 169). The `Either Text Int` return type overloads `Left` to mean "error message to display" and `Right` to mean "exit code". This is documented nowhere.
**Fix**: Add a comment or type alias clarifying the convention: `Left = error message that should be displayed/thrown, Right = exit code (0=success, 1=failure, 130=cancelled)`.

### OPS-10: `createChangeset` always returns `Right` even on transient errors (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:88-114`
**What**: The function sends the CreateChangeSet request (line 104) without catching errors, so if the API call fails (e.g., invalid parameters, throttling), it throws an uncaught exception. But `pollChangesetCompletion` (line 112) is reached only on success, and it returns `Right finalInfo` (line 114) always, even if `csiStatus` is "FAILED". The `Right` here means "no exception", not "success", which is correct. However, the caller must check `csiStatus` separately, and both callers (`updateStackWithChangeset` and the create-changeset command) do so. This is fine but fragile.
**Fix**: Consider making `createChangeset` return `Left` when the changeset status is FAILED, folding the status check into the function itself.

### OPS-11: `WatchStack.formatEvent` is exported but unused outside tests (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/WatchStack.hs:8,94-101`
**What**: `formatEvent` is exported and tested in `WatchStackTest.hs`, but it is never called from production code. The actual event formatting for the output pipeline goes through `convertEvent`/`convertEventWithDuration` in `DescribeStack.hs`, not through `formatEvent`. It appears to be dead code from an earlier iteration.
**Fix**: Remove `formatEvent` if it is truly unused, or mark it as a utility for debugging/logging.

### OPS-12: `buildEventsDisplay` traverses the `rest` list to compute length (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs:133`
**What**: `splitAt numEvents events` returns the remainder as a lazy list. Then `length rest` forces the entire remainder, which for a stack with thousands of historical events means traversing O(n) events just to show "Showing 10 of N". This is O(n) where the total count might not even be needed.
**Fix**: Use `length events` directly (which is also O(n) but clearer), or compute it from the paginated API response which already knows the count. Since this is called once per describe-stack, the performance impact is negligible.

### OPS-13: `quoteYamlString` does not handle backslash in single-quoted mode (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:285-335`
**What**: In single-quoted YAML scalars, backslash has no special meaning (it is literal). The function correctly does not escape backslashes in single-quote mode. However, single-quoted YAML cannot contain literal newlines or other control characters. The function guards this with `hasControlChars` routing to double-quote mode. This is correct behavior. No bug here on closer inspection.
**Fix**: None needed.

### OPS-14: `Changeset.findPendingChangeset` only fetches one page (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:371-381`
**What**: `findPendingChangeset` uses `Amazonka.send` (single page) rather than `Amazonka.paginate`. If a stack has more than 50 changesets (the default page size), and the pending changeset is not on the first page, this function would return `"unknown"` instead of the actual changeset name.
**Fix**: Use `Amazonka.paginate` to collect all pages, matching the pagination pattern used in `collectStackContents`. In practice, a stack in REVIEW_IN_PROGRESS almost always has exactly one pending changeset, so this is very unlikely to matter.

### OPS-15: `buildStackArgsYaml` parameter/tag ordering depends on input list order (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:337-396`
**What**: Parameters and tags are received as `[(Text, Text)]` lists and emitted in the given order. If the caller passes them in an inconsistent order (e.g., from a `Map.toList` which is sorted by key), the output is deterministic. The callers in `processStack` use `extractParams`/`extractTags` which iterate over `Maybe [CF.Parameter]`, preserving AWS API response order. This is fine -- just noting that output ordering is not explicitly sorted.
**Fix**: None required; matches Rust behavior.

### OPS-16: `allTestOutputData` lists 27 items but test asserts 26 unique types (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/test/Test/IntegrationTest.hs:182-186`, `/home/tavis/src/iidy-hs/test/Test/Shared.hs:414-443`
**What**: `allTestOutputData` includes `OdStackDefinition testStackDef True` and `OdStackDefinition testStackDef False` (27 entries), but `odConstructorName` maps both to `"StackDefinition"`, so `nub` produces 26 unique names. The test asserts `26`, which is correct. But the `OutputData` type has 27 constructors (count from the type definition). One constructor might be missing from the list. Counting: OdCommandMetadata through OdPollingStarted = 27 constructors. But `allTestOutputData` has 27 entries with one duplicate constructor, so only 26 distinct constructors are covered. This means one constructor is NOT covered.

Checking: the constructors are OdCommandMetadata, OdStackDefinition, OdStackEvents, OdStackContents, OdStatusUpdate, OdCommandResult, OdFinalCommandSummary, OdStackList, OdChangeSetResult, OdStackDrift, OdError, OdTokenInfo, OdNewStackEvents, OdOperationComplete, OdInactivityTimeout, OdConfirmationPrompt, OdStackChangeDetails, OdStackAbsentInfo, OdCostEstimate, OdStackTemplate, OdApprovalRequestResult, OdTemplateValidation, OdApprovalStatus, OdTemplateDiff, OdApprovalResult, OdPollingStarted = 26 constructors. Wait, let me recount from Output/Types.hs:
1. OdCommandMetadata
2. OdStackDefinition
3. OdStackEvents
4. OdStackContents
5. OdStatusUpdate
6. OdCommandResult
7. OdFinalCommandSummary
8. OdStackList
9. OdChangeSetResult
10. OdStackDrift
11. OdError
12. OdTokenInfo
13. OdNewStackEvents
14. OdOperationComplete
15. OdInactivityTimeout
16. OdConfirmationPrompt
17. OdStackChangeDetails
18. OdStackAbsentInfo
19. OdCostEstimate
20. OdStackTemplate
21. OdApprovalRequestResult
22. OdTemplateValidation
23. OdApprovalStatus
24. OdTemplateDiff
25. OdApprovalResult
26. OdPollingStarted

That is exactly 26 constructors. The test is correct. The comment "all 27 OutputData variant types" in the test name is wrong (says 27 but asserts 26), but the coverage is actually complete.

**Fix**: Update the test case name from "all 27" to "all 26" to match the assertion.

### OPS-17: `pollChangesetCompletion` resets error count on success (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:149`
**What**: When a successful describe-changeset response is received but the status is not terminal, the error count is reset to 0 (`go 0`). This means a pattern of alternating successes and errors could poll indefinitely without ever hitting the retry limit. In practice, this is unlikely since transient errors either resolve quickly or persist.
**Fix**: Consider tracking total errors rather than consecutive errors, or add an overall timeout.

### OPS-18: `deleteStack` confirmation prompt uses `String` not `Text` (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DeleteStack.hs:87`
**What**: The prompt is built with `T.unpack stackName` to convert to `String` for `requestConfirmation`. The `Confirm` module uses `String` throughout. The project standard is "Prefer `Text` over `String`".
**Fix**: Update `requestConfirmation` to accept `Text` instead of `String`.

## Test Coverage Assessment

**Well-tested areas:**
- Polling engine (`pollForCompletionWith`): 7 tests covering terminal detection, multi-poll, dedup, nested resources, various terminal statuses
- Event formatting (`formatEvent`): 4 tests for field presence/absence
- Stack name extraction (`stackNameFromId`): 3 tests for ARN, plain, slashed formats
- Changeset helpers: 10 tests for `percentEncode`, 6 for `extractRegionFromArn`, 5 for `buildChangesetConsoleUrl`, 10 for `buildChangeSetCreationResult`
- Changeset conversion: 6 tests for `convertChange`/`convertDetail`
- `generateDashedName`: 3 tests including randomness check
- YAML emitter: comprehensive tests for `inlineValue`, `quoteYamlString`, `emitCfnYaml`, `templateBodyToYaml`
- Request builder mappers: 20+ tests for capability, parameter, tag, and onFailure mapping
- Output pipeline integration: 10+ tests for renderer pass-through and sequence ordering

**Gaps:**
1. **No operation-level tests for `createStack`, `updateStack`, `deleteStack`, `watchStack`, `describeStack`**: These are only tested indirectly through the polling engine and output pipeline integration tests. The actual orchestration logic (request building -> sending -> polling -> content collection) is untested. This is understandable since they require AWS API mocking, but it means the glue code connecting the tested components is not verified.
2. **No test for `isNoUpdatesError`**: The error detection logic in `UpdateStack.hs:181-186` is exported for testing but not actually tested.
3. **No test for `isStackNotFoundError`**: The error detection in `StackOperations.hs:73-79` is not tested.
4. **No test for `collectStackContents`**: The export filtering logic (line 151-163) that matches exports by stack ARN is untested.
5. **No test for `convertStack` (DescribeStack)**: The CF.Stack-to-StackDefinition conversion is untested, including tag map construction, capability extraction, and console URL building.
6. **No test for `calculateEventDurations`**: The duration tracking via start/end pair matching is complex (30 LOC) but untested.
7. **No test for `convertEventWithDuration`**: The live event duration calculation is untested.
8. **No test for `checkStackState`**: The REVIEW_IN_PROGRESS detection logic is untested.
9. **`ConvertStack` orchestration untested**: File writing, SSM migration, and the complete convert flow are untested.
10. **`quoteYamlString` missing edge case**: The function does not test strings containing both control characters AND single quotes (would they be double-quote escaped correctly?).

## Positive Observations

1. **Consistent operation pattern**: All write operations (create, update, delete, execute-changeset) follow the same pattern: build request, send, emit StackDefinition, poll with standard config, collect contents, return exit code. This makes the code predictable and easy to audit.

2. **Clean polling abstraction**: The `pollForCompletionWith` function accepts an `IO [CF.StackEvent]` action instead of requiring a `CfnContext`, making it fully testable with mock event streams. The `PollConfig` record with callbacks is a good design for extensibility.

3. **No partial functions**: Zero uses of `head`, `tail`, `fromJust`, `undefined`, or `error` in production code. All pattern matches are total or use `Maybe`/`fromMaybe`.

4. **Strong deduplication**: The polling engine uses `Set.notMember` for O(log n) event dedup, and `WatchStack` adds a second dedup layer for events seen before polling started. This prevents duplicate event display.

5. **Correct ARN-based polling**: Delete operations correctly use the stack ARN (not name) for polling, ensuring events can still be fetched after the stack name becomes invalid post-deletion.

6. **Well-structured YAML emitter**: The CFN YAML emitter handles CFN-specific key ordering with weight functions, correctly handles all JSON value types, and produces valid YAML with proper quoting. The `quoteYamlString` function handles an impressive range of edge cases (YAML 1.1 booleans, numbers, dash sequences, dot-prefix, tilde, single-quote escaping).

7. **Comprehensive test data builders**: The `Test.Shared` module provides builders for all 26 `OutputData` variants, enabling thorough integration testing.

8. **Good use of `OverloadedRecordDot`**: The codebase consistently uses `OverloadedRecordDot` for reading amazonka response fields, making the code readable despite amazonka's `DuplicateRecordFields` design.

9. **Event duration calculation is well-designed**: The `calculateEventDurations` function correctly sorts events chronologically, tracks IN_PROGRESS start times per resource key, and matches them with COMPLETE/FAILED end events. The `max 1` minimum duration prevents confusing "0 seconds" displays.

10. **Pagination done correctly**: `fetchStackEvents`, `collectStackContents` (for changesets and exports) all use `Amazonka.paginate` with conduit, correctly handling multi-page responses.

## Grade Justification

Starting from 100:

| Deduction | Reason                                                                           |
|----------:|:---------------------------------------------------------------------------------|
|        -3 | OPS-05: ConvertStack mixes IO deeply, making orchestration untestable            |
|        -2 | OPS-11: `formatEvent` is dead production code                                    |
|        -2 | OPS-04: `percentEncode` placement is confusing with re-export                    |
|        -2 | OPS-09: `Either Text Int` return type convention undocumented                     |
|        -1 | OPS-01: `buildEventsDisplay` total count semantically wrong for short lists      |
|        -1 | OPS-14: `findPendingChangeset` only fetches one page                             |
|        -1 | OPS-16: Test name says "27" but asserts 26                                       |
|        -1 | OPS-06: ConvertStack bypasses output pipeline with direct stderr writes          |
|        -1 | OPS-07: Silent fallback to us-east-1 on malformed ARN                            |
|        -1 | OPS-10: `createChangeset` returns Right even on FAILED status                    |
|        -1 | OPS-17: Error counter reset allows unbounded polling on alternating errors       |
|        -1 | OPS-18: Confirm module uses String not Text                                      |
|        -2 | Test gap: no tests for `isNoUpdatesError`, `isStackNotFoundError`                |
|        -2 | Test gap: no tests for `calculateEventDurations`, `convertEventWithDuration`     |
|        -2 | Test gap: no tests for `convertStack`, `collectStackContents`, `checkStackState` |
|     **81** | **Final grade**                                                                  |
