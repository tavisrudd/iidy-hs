# Code Review 3c: CFN Operations & Polling Engine

**Date**: 2026-03-01
**Reviewer**: Claude Opus 4.6
**Scope**: 12 production files, 9 test files (21 total)

## Files Reviewed

| File                                         | Lines | Role                           |
|----------------------------------------------|------:|--------------------------------|
| `src/Iidy/Cfn/Context.hs`                   |   114 | Operation context / token mgmt |
| `src/Iidy/Cfn/RequestBuilder.hs`            |   193 | CFN API request construction   |
| `src/Iidy/Cfn/StackOperations.hs`           |   293 | Polling engine, stack queries  |
| `src/Iidy/Cfn/Operations/ConvertStack.hs`   |   534 | Stack-to-iidy file conversion  |
| `src/Iidy/Cfn/Operations/CreateStack.hs`    |   114 | Create stack operation         |
| `src/Iidy/Cfn/Operations/UpdateStack.hs`    |   226 | Update stack (direct + cs)     |
| `src/Iidy/Cfn/Operations/DeleteStack.hs`    |   128 | Delete stack operation         |
| `src/Iidy/Cfn/Operations/Changeset.hs`      |   448 | Changeset create/exec/describe |
| `src/Iidy/Cfn/Operations/WatchStack.hs`     |   122 | Watch-stack polling observer   |
| `src/Iidy/Cfn/Operations/CreateOrUpdate.hs` |   167 | Create-or-update dispatcher    |
| `src/Iidy/Cfn/Operations/DescribeStack.hs`  |   212 | Describe stack + event display |
| `src/Iidy/Cfn/Operations/DescribeStackDrift.hs` | 186 | Drift detection flow       |
| `test/Test/ConvertStackTest.hs`              |   105 | ConvertStack pure fn tests     |
| `test/Test/CfnYamlEmitterTest.hs`           |   248 | YAML emitter tests             |
| `test/Test/ChangesetHelpersTest.hs`         |   229 | Changeset helper tests         |
| `test/Test/WatchStackTest.hs`               |   187 | Watch-stack + polling tests    |
| `test/Test/DeleteStackTest.hs`              |    30 | Confirmation logic tests       |
| `test/Test/ChangesetTest.hs`                |   107 | Changeset conversion tests     |
| `test/Test/RequestBuilderTest.hs`           |    75 | Request builder mapping tests  |
| `test/Test/Phase14FixTest.hs`               |   180 | Assorted bug-fix regression    |
| `test/Test/IntegrationTest.hs`              |   238 | Renderer integration tests     |
| **Total**                                    | **4136** |                            |

## Grade: 78/100

## Summary

The CFN operations layer is well-structured with clean separation between the polling engine, individual operations, request building, and context management. The architecture is sound: each operation module follows a consistent pattern of build-request -> send -> poll -> collect -> return. The polling engine uses dependency injection (`pollForCompletionWith`) for testability, which is a good design decision.

However, there are several issues of varying severity. The most concerning is that `moveParamsToSSM` silently swallows errors and reports migrated keys that may have failed, which could produce stack-args files referencing non-existent SSM parameters. There is significant code duplication across operation modules (5 copies of `allTerminalStatuses`, duplicated polling configuration boilerplate). The `sortCfnKeys`/`sortCfnValue` functions are dead code, and the poll timeout contract uses empty string as a sentinel value instead of a proper sum type. The exports field in `collectStackContents` is hardcoded to `[]`, representing an incomplete feature.

## Issues Found

### OPS-01: moveParamsToSSM silently swallows errors and lies about results (Severity: Critical)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:524-534`
**What**: When `PutParameter` fails for a specific parameter, the exception is caught and discarded via `try`. However, the function still returns that parameter's key in the success list (line 534: `pure (map fst eligible)`). The caller then generates `stack-args.yaml` with `!$ ssmParams.key` references to SSM parameters that were never actually written.
**Fix**: Track which parameters succeeded. Either accumulate results with `mapM` returning `Either`, or filter the `eligible` list to only include parameters that were successfully written. At minimum, print a warning to stderr on failure and exclude the key from the returned list.

### OPS-02: sortCfnKeys/sortCfnValue are dead code with a latent correctness bug (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:169-187`
**What**: `sortCfnValue` sorts pairs then reassembles them via `KM.fromList`. Since `KeyMap` is backed by `HashMap`, insertion order is not preserved -- the sort has no effect on the resulting `Object`. These functions are never called from production code; only `sortCfnKeys` is exported for testing but the tests named "sortCfnKeys" actually test `templateBodyToYaml` (which uses the emitter path, not `sortCfnKeys`). The actual sorting works correctly via `emitCfnYaml`/`emitValue` which sorts during emission.
**Fix**: Remove `sortCfnKeys` and `sortCfnValue` as dead code. Remove `sortCfnKeys` from the export list.

### OPS-03: allTerminalStatuses duplicated 5 times with inconsistent contents (Severity: Major)
**File**: Multiple files in `src/Iidy/Cfn/Operations/`
**What**: `allTerminalStatuses :: [Text]` is defined independently in `CreateStack.hs`, `UpdateStack.hs`, `DeleteStack.hs`, `Changeset.hs`, and `WatchStack.hs`. The lists differ:
- CreateStack/UpdateStack have 14 entries (including `DELETE_SKIPPED`, `REVIEW_IN_PROGRESS`)
- Changeset has 11 entries
- DeleteStack has 6 entries
- WatchStack has 13 entries (includes `UPDATE_FAILED` but no `DELETE_SKIPPED`/`REVIEW_IN_PROGRESS`)

The DeleteStack list is intentionally narrower (only delete-relevant statuses), which is correct. But CreateStack and UpdateStack including `REVIEW_IN_PROGRESS` as terminal is questionable -- this is not a terminal state but a pending state.
**Fix**: Extract common terminal statuses to `Iidy.Cfn.Context` or a shared module. Allow operation-specific overrides where needed (e.g., delete-stack's narrower list). Audit whether `REVIEW_IN_PROGRESS` and `DELETE_SKIPPED` should be terminal for create/update.

### OPS-04: Polling returns empty string on timeout -- weak contract (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs:214,219`
**What**: `pollForCompletion` returns `""` on both inactivity timeout and overall timeout. Callers check `finalStatus `elem` successStates`, which works (empty string is not a success state), but this is a fragile sentinel-value pattern. A caller could mistakenly use `finalStatus` as a status string in output, or a future change could break the implicit contract.
**Fix**: Return `Maybe Text` or a dedicated `data PollResult = PollSuccess Text | PollTimeout | PollInactivityTimeout` so callers handle each case explicitly.

### OPS-05: collectStackContents hardcodes scExports to empty list (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs:132`
**What**: `scExports = []` with the comment "Exports require separate ListExports call". The renderers have full export rendering logic (Interactive.hs lines 638-651, Json.hs line 332), but the data is never populated. This is a missing feature -- stack exports are never displayed.
**Fix**: Add a `ListExports` call to `collectStackContents`, filter exports to those from the current stack, and populate `scExports`.

### OPS-06: describeChangesetRaw catches only Amazonka.Error, not SomeException (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:271-272`
**What**: The error handler uses `catch` with `Amazonka.Error`, but network-level exceptions (e.g., `HttpExceptionRequest`, `IOException`) will not be caught. This is inconsistent with `convertStackToIidy` which catches `SomeException`.
**Fix**: Either catch `SomeException` for consistency, or document that only AWS API errors are handled and network failures propagate.

### OPS-07: determineOperationSuccess and ctxElapsedSeconds are dead code (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Context.hs:82-85,112-114`
**What**: `ctxElapsedSeconds` is exported but never called anywhere in the codebase. `determineOperationSuccess` is exported but never called -- each operation module inlines `finalStatus `elem` xxxSuccessStates` instead of using this helper.
**Fix**: Either use `determineOperationSuccess` in the operation modules (reduces duplication), or remove both dead functions from the module.

### OPS-08: Duplicated poll configuration boilerplate across 5 operation modules (Severity: Minor)
**File**: `CreateStack.hs:95-100`, `UpdateStack.hs:140-145`, `DeleteStack.hs:116-121`, `Changeset.hs:223-228`, `WatchStack.hs:88-99`
**What**: Every operation module builds a `PollConfig` with nearly identical `pcOnNewEvents` and `pcOnOperationComplete` callbacks that convert events and emit them. The pattern is:
```haskell
pcOnNewEvents = \newEvents -> do
    let converted = map (convertEventWithDuration (cfnStartTime ctx)) newEvents
    emit (OdNewStackEvents converted)
, pcOnOperationComplete = \info -> emit (OdOperationComplete info)
```
**Fix**: Extract a helper like `mkStandardPollConfig :: CfnContext -> (OutputData -> IO ()) -> PollConfig` that provides the common callback wiring.

### OPS-09: buildConsoleUrl does not percent-encode the ARN (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs:206-212`
**What**: The stack info console URL embeds a raw ARN (containing colons and slashes) directly in the URL without percent-encoding. While the changeset URL correctly percent-encodes ARNs, the stack info URL does not. Browsers may handle this, but it is technically an invalid URL per RFC 3986.
**Fix**: If Rust matches this behavior, document the intentional divergence. Otherwise, apply `percentEncode` to the `stackArn` parameter.

### OPS-10: ConvertStack.hs exceeds 500 LOC limit (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs` (534 lines)
**What**: The coding standards say "try to keep modules under ~300-500 LOC; split if larger and possible." ConvertStack.hs at 534 lines exceeds this. The file contains three distinct concerns: YAML emitter logic (~180 LOC), CFN key sorting/weight functions (~100 LOC), and stack conversion/SSM migration (~250 LOC).
**Fix**: Extract the YAML emitter (`emitCfnYaml`, `emitValue`, `emitPair`, `emitItem`, `inlineValue`, `quoteYamlString`, `chooseWeightFn`, weight functions) into a separate `Iidy.Cfn.CfnYamlEmitter` module.

### OPS-11: quoteYamlString missing newline detection (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:297-308`
**What**: The `needsQuoting` check handles many YAML special characters but does not check for embedded newlines, tabs, or other control characters. A string containing `\n` would be emitted unquoted, producing invalid YAML (the newline would break the flow scalar).
**Fix**: Add `T.any (< ' ') t` or `T.any (\c -> c == '\n' || c == '\r' || c == '\t') t` to `needsQuoting`.

### OPS-12: generateDashedName has very small vocabulary (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:433-441`
**What**: 8 adjectives x 8 nouns = 64 unique names. For a changeset name that needs to be unique across potentially many operations, 64 possibilities is low. Collisions are likely if a stack has many changesets created over time.
**Fix**: Either expand the vocabulary significantly (Rust/Docker use hundreds of words), or append a random numeric suffix.

### OPS-13: Unused import in WatchStack.hs (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/WatchStack.hs:18`
**What**: `import qualified Amazonka.CloudFormation as CF` is imported but all uses of `CF.` qualify types from `Amazonka.CloudFormation.Types` which is separately imported on line 19. The `Amazonka.CloudFormation` main module re-exports Types, so both imports resolve, but the first import is redundant.
**Fix**: Remove `import qualified Amazonka.CloudFormation as CF` and keep only `import qualified Amazonka.CloudFormation.Types as CF`.

### OPS-14: pollChangesetCompletion resets error count on any success (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:171`
**What**: `go 0  -- reset error count on success` means that if there are 29 failures, then 1 success, then 30 more failures, the function will keep retrying indefinitely rather than failing after 30 total errors. For a polling loop, this is probably acceptable (transient errors between successes are normal), but it means the 30-retry limit only applies to consecutive failures.
**Fix**: Clarify in the doc comment that the retry limit is for consecutive failures, or track total errors separately if a hard cap is desired.

## Test Coverage Assessment

### Well-tested areas:
- **YAML emitter**: `CfnYamlEmitterTest` (37 tests) provides thorough coverage of `inlineValue`, `quoteYamlString`, `emitCfnYaml`, and `templateBodyToYaml` round-trips.
- **Changeset helpers**: `ChangesetHelpersTest` (26 tests) covers `percentEncode`, `extractRegionFromArn`, `buildChangesetConsoleUrl`, and `buildChangeSetCreationResult` comprehensively.
- **Polling engine**: `WatchStackTest` (13 tests) validates `pollForCompletionWith` with mock event streams -- terminal detection, multi-poll, callback filtering, nested resources.
- **Changeset conversion**: `ChangesetTest` (10 tests) covers `convertChange`, `convertDetail`, `generateDashedName` edge cases.
- **Request builder**: `RequestBuilderTest` (15 tests) covers all mapping functions.
- **Integration**: `IntegrationTest` validates all 26 `OutputData` variants render without crashing.

### Coverage gaps:
- **No tests for any operation module's main function** (`createStack`, `updateStack`, `deleteStack`, `watchStack`, `createOrUpdate`, `describeStack`, `describeStackDrift`, `convertStackToIidy`). All of these require AWS mocking. The polling engine is tested via `pollForCompletionWith` DI, but the operations themselves are only tested through integration sequences.
- **No tests for `buildStackArgsYaml` edge cases**: empty project name, empty stack name, all optional fields enabled simultaneously, special characters in parameter values.
- **No tests for `sortCfnKeys` (and it is dead code)**: The test names reference `sortCfnKeys` but actually test `templateBodyToYaml`.
- **No tests for `collectStackContents`**, `getStack`, `stackExists`, `fetchStackEvents` -- all AWS-dependent.
- **No tests for `checkStackState`**, `findPendingChangeset`, `needsDriftCheck`, `pollDriftDetection`.
- **`DeleteStackTest` is thin** (10 tests): Only tests `isConfirmation`, nothing specific to delete-stack logic.
- **No tests for `parameterizeEnv` interaction with multiple environments in one string** (e.g., "production-staging" would become "{{environment}}-{{environment}}").
- **No property tests for `percentEncode`** (decode(encode(x)) == x roundtrip).

## Positive Observations

1. **Clean polling architecture**: The `pollForCompletionWith` function accepting an `IO [CF.StackEvent]` parameter instead of requiring a `CfnContext` is an excellent dependency injection pattern that enables thorough testing without AWS mocks.

2. **Consistent operation structure**: All operation modules follow the same pattern: check preconditions, build request, send, emit stack definition, poll, collect contents, return exit code. This makes the codebase predictable and easy to navigate.

3. **Good event deduplication strategy**: The polling engine uses `Set Text` for event ID tracking with O(log n) per-event membership checks. The watch-stack module correctly adds a second dedup layer for the pre-polling/polling boundary.

4. **Well-factored request builder**: `RequestBuilder.hs` cleanly separates request construction from the operation logic, with pure helper functions (`mapCapability`, `mapParameters`, etc.) that are independently testable.

5. **Thorough YAML emitter**: The custom CFN YAML emitter handles all edge cases (empty collections, nested objects in arrays, key sorting) and correctly sorts during emission rather than relying on HashMap ordering.

6. **CfnContext token tracking**: The `IORef`-based token tracking with `ctxDeriveToken` accumulating derived tokens is a clean approach for idempotency token management.

7. **Type-safe CloudFormation status conversion**: Using `CF.fromStackStatus`, `CF.fromResourceStatus`, etc. throughout rather than raw strings at the API boundary.

8. **Good test organization**: Test modules are well-structured with clear groupings. The `Phase14FixTest` module serves as targeted regression tests for specific bugs, which is good practice.

## Grade Justification

Starting from 100:

| Deduction | Issue | Reason |
|----------:|-------|--------|
|        -5 | OPS-01 | Critical: silent error swallowing produces incorrect output files |
|        -3 | OPS-02 | Dead code with latent bug (KM.fromList ordering) |
|        -3 | OPS-03 | 5x duplication of terminal statuses, inconsistent contents |
|        -3 | OPS-04 | Empty string as timeout sentinel instead of proper type |
|        -2 | OPS-05 | Exports feature incomplete (hardcoded to []) |
|        -1 | OPS-06 | Inconsistent error catching scope |
|        -1 | OPS-07 | Dead exported functions |
|        -1 | OPS-08 | Repeated poll config boilerplate |
|        -1 | OPS-09 | Unencoded ARN in URL |
|        -1 | OPS-10 | Module exceeds size guideline |
|        -1 | OPS-11 | Missing newline detection in YAML quoting |
|     **-22** | **Total** | **Grade: 78/100** |

The codebase is solid production code with good architecture and reasonable test coverage for the pure logic. The main deductions come from the critical SSM error-swallowing bug, dead code accumulation, and the duplication across operation modules that could be factored out. The test suite is strong on pure functions but has no coverage of the operation orchestration layer.
