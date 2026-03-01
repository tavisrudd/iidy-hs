# Code Review R13: CFN Operations & Polling

**Date**: 2026-03-01
**Round**: 13
**Scope**: CFN operations, polling engine, YAML emitter, changeset operations
**Prior reviews**: none (independent review)
**Note**: Architectural items listed in known-deferred list are excluded from this review.

## Grade: 83/100
## Letter Grade: B
## Trust Assessment

This codebase demonstrates consistently competent engineering across 81 modules and 811 tests. The polling engine is well-designed with dependency injection for testability. The CFN operations follow a clear, repeatable pattern (build request, send, poll, collect, return exit code). There is one genuine correctness gap (stack policy not passed through to create requests) and one minor behavioral gap (roleARN fallback), both of which are Rust-parity issues rather than logical errors in existing code. The test suite is solid for pure functions but lacks coverage of several important conversion functions. Overall, this is production-grade code with a few specific gaps.

## Summary

The 12 production files under review implement the full CloudFormation operation lifecycle: create, update, delete, watch, create-or-update, changeset management, drift detection, stack conversion, and supporting infrastructure (context, request builder, polling). The code is well-organized, with clear separation between the polling engine (StackOperations), individual operations, and request building. The YAML emitter in ConvertStack is thorough with comprehensive quoting rules. The main issues found are: (1) stack policy not forwarded to CreateStack API calls, (2) missing `saRoleArn` fallback in request builders, (3) a few untested pure conversion functions, and (4) minor robustness concerns.

## Issues Found

### OPS-01: Stack policy not passed through to CreateStack request (Severity: Major)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/RequestBuilder.hs:58-73`
**What**: The Rust `build_create_stack` (request_builder.rs:170-185) loads and passes `stack_policy_body` or `stack_policy_url` when `stack_args.stack_policy` is set. The Haskell `buildCreateStackRequest` does not set `CS.stackPolicyBody` or `CS.stackPolicyURL` at all, despite `StackArgs` having a `saStackPolicy :: Maybe Value` field. Users who specify `StackPolicy` in their stack-args.yaml will silently have it ignored during stack creation.
**Fix**: Add stack policy loading to `TemplateResult` or a separate loader, then set the appropriate field on the CreateStack request. At minimum, load the JSON value and set `CS.stackPolicyBody`.

### OPS-02: Missing `saRoleArn` fallback in request builders (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/RequestBuilder.hs:65,96,132`
**What**: The Rust request builders check `service_role_arn` first, then fall back to `role_arn` (request_builder.rs:132-136). The Haskell only uses `saServiceRoleArn args` and never checks `saRoleArn args`. If a user's stack-args uses `RoleARN` instead of `ServiceRoleArn`, it will be silently ignored. Both fields exist in `StackArgs`.
**Fix**: Add fallback: `CS.roleARN = saServiceRoleArn args <|> saRoleArn args` (and similarly for US and CCS).

### OPS-03: `collectStackContents` on PollInactivityTimeout in watchStack (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/WatchStack.hs:86-91`
**What**: When polling ends with `PollInactivityTimeout`, the wildcard case falls through to `collectStackContents`. While functionally correct (the stack is still there), it could result in an unnecessary API call after a timeout situation. This is a minor efficiency concern rather than a bug, and the Rust behavior is similar.
**Fix**: None required; this is consistent with the intended behavior of showing current state even on timeout. Noting for awareness only.

### OPS-04: `convertEvent` not directly unit-tested (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs:146-159`
**What**: `convertEvent` is a pure function that converts `CF.StackEvent` to the output `StackEvent` type. It handles 11 field mappings including `fromMaybe` defaults and optional field extraction. Despite being exported and pure, it has no direct unit tests. It is exercised indirectly through `calculateEventDurations` tests (which call it via the `mkEvent` helper that builds output `StackEvent` directly, bypassing `convertEvent`).
**Fix**: Add direct tests for `convertEvent` using `SE.newStackEvent` with various field combinations, verifying all 11 field mappings.

### OPS-05: `convertStack` not directly unit-tested (Severity: Minor)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs:87-123`
**What**: `convertStack` converts a `CF.Stack` into a `StackDefinition` with 18 fields. It handles capabilities extraction, tag/parameter map construction, notification ARNs, and console URL generation. It is exported and pure but has no direct unit tests. Tests for `buildConsoleUrl` exist but the parent function is untested.
**Fix**: Add at least one test constructing a `CF.Stack` value and verifying the output `StackDefinition` fields.

### OPS-06: `buildEventsDisplay` count semantics could mislead (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs:130-143`
**What**: `buildEventsDisplay` uses `splitAt numEvents events` where events arrive most-recent-first from the API. The `truncTotal` field sums `length taken + length rest` to report total events. This is correct. However, the title says "Previous Stack Events (max N)" while the actual semantics are "most recent N events." This is consistent with the Rust UI, so not a real issue.
**Fix**: None needed (Rust parity).

### OPS-07: `convertDescribeResponse` field access on non-Maybe status (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:260`
**What**: `csiStatus = CF.fromChangeSetStatus resp.status` accesses `resp.status` directly. In the amazonka DescribeChangeSetResponse type, `status` is `ChangeSetStatus` (required, not `Maybe`). This is correct. However, it's the only field in `convertDescribeResponse` accessed without `fromMaybe` protection. Worth confirming it's truly required in the AWS SDK.
**Fix**: None needed if confirmed non-Maybe. Verify via the amazonka type definition.

### OPS-08: `pollChangesetCompletion` resets error count on success but keeps totalIterations (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs:154`
**What**: When a successful (Right) response is received but the changeset isn't yet terminal, `go 0 (totalIterations + 1)` resets `errorCount` to 0. This is sensible (transient errors followed by success should reset the retry budget). The design is correct; noting it as a positive observation.
**Fix**: None needed.

### OPS-09: `watchStack` second dedup layer captures closure over `seenIds` (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/WatchStack.hs:72-75`
**What**: The second dedup layer creates a closure over `seenIds` (the initial event set). This set is immutable after creation, so events emitted during polling that were NOT in the initial fetch will correctly pass through. However, if the initial `fetchStackEvents` returns events that are later re-returned by the polling `fetchStackEvents`, the dedup in `pollForCompletionWith` (via `lastEventSet`) should catch them. The second layer adds belt-and-suspenders safety. Correct behavior.
**Fix**: None needed.

### OPS-10: `deleteStack` uses `cfnPrimaryToken` indirectly via `buildDeleteStackRequest` which derives a new token (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/RequestBuilder.hs:104-105`
**What**: `buildDeleteStackRequest` always derives a token via `ctxDeriveToken ctx "delete-stack"` rather than using the primary token. The Rust delete uses the primary token directly (`context.primary_token()`). This means the Haskell delete will have a different token value than the Rust delete for the same operation. This is unlikely to cause issues since tokens are just idempotency keys, but it's a behavioral divergence.
**Fix**: Consider using the primary token directly for delete, matching Rust behavior: `let token = cfnPrimaryToken ctx`.

### OPS-11: `emitCfnYaml` key order when `doSort=False` depends on KeyMap iteration order (Severity: Nitpick)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs:197-201`
**What**: When `doSort` is False, `KM.toList km` is used, which iterates in the KeyMap's internal order (HashMap-based in aeson, so effectively arbitrary). For JSON input this means key order is unpredictable. For YAML input, `Data.Yaml.decodeEither'` also produces a HashMap-backed KeyMap, so order is lost. The Rust version likely preserves insertion order from serde_yaml. This means `convertStackToIidy` with `sortkeys=False` may produce different key ordering than Rust.
**Fix**: This is likely already known and acceptable (documented in DIVERGENCES.md for serde_yaml format differences). No action needed.

## Test Coverage Assessment

### Well-tested pure functions:
- `stackNameFromId` (3 tests: ARN, plain name, multi-slash)
- `isStackNotFoundError` (6 tests: positive, negative code, negative message, no message, non-ServiceError)
- `isNoUpdatesError` (8 tests across WatchStackTest and Phase14FixTest)
- `pollForCompletionWith` (8 tests: terminal detection, multi-poll, callback filtering, nested resource ignore, DELETE_COMPLETE, UPDATE_ROLLBACK_COMPLETE, timeout, inactivity timeout)
- `calculateEventDurations` (8 tests: matching pair, floor clamp, no start, empty, FAILED, multi-resource, no timestamp, sub-second)
- `convertEventWithDuration` (2 tests: sub-second, exact seconds)
- `buildConsoleUrl` (3 tests: basic, encoded ARN, different region)
- `percentEncode` (10 tests: empty, letters, digits, unreserved, colon, slash, ARN, space, hash, Unicode)
- `extractRegionFromArn` (6 tests: standard, us-west-2, eu-central-1, changeset ARN, malformed, empty)
- `buildChangesetConsoleUrl` (5 tests)
- `buildChangeSetCreationResult` (10 tests)
- `convertChange` (5 tests: no resourceChange, missing logicalId, missing resourceType, valid, minimal)
- `convertDetail` (2 tests: full, empty)
- `generateDashedName` (3 tests: format, non-empty, variety)
- `formatAmazonkaError` (3 tests)
- `isNonRetryableError` (6 tests)
- `mapCapability`, `mapCapabilities`, `mapParameters`, `mapTags`, `mapOnFailure` (20 tests total)
- `parameterizeEnv`, `parameterizeStackName` (5 tests)
- `templateBodyToYaml` (4 tests)
- `buildStackArgsYaml` (2 tests: basic, SSM)
- `quoteYamlString` (25+ tests: comprehensive coverage)
- `inlineValue` (7 tests)
- `emitCfnYaml` (12+ tests)
- `buildCliArguments` (3 tests)
- `getStrMapValidated` (5 tests)
- `credentialDisplayName` / `sourceDisplayName` (6 tests)

### Gaps in test coverage:

1. **`convertEvent`** (DescribeStack.hs:146-159): Pure `CF.StackEvent -> StackEvent` conversion with 11 fields. No direct tests.

2. **`convertStack`** (DescribeStack.hs:87-123): Pure `CF.Stack -> StackDefinition` with 18 fields including capabilities extraction, tag map construction, console URL. No direct tests.

3. **`convertResource`** (StackOperations.hs:310-318): Pure `CF.StackResource -> StackResourceInfo`. No tests.

4. **`convertOutput`** (StackOperations.hs:320-328): Pure `CF.Output -> Maybe StackOutputInfo`. No tests.

5. **`convertChangeSetSummary`** (StackOperations.hs:330-345): Pure `CF.ChangeSetSummary -> Maybe ChangeSetInfo`. No tests.

6. **`convertDescribeResponse`** (Changeset.hs:253-265): Pure `DCS.DescribeChangeSetResponse -> ChangeSetInfo`. No tests.

7. **`checkStackState`** / **`findPendingChangeset`** (Changeset.hs:389-417): IO-bound but the state machine logic could be tested with mocks.

8. **`needsDriftCheck`** / **`checkTimestampStale`** (DescribeStackDrift.hs:106-124): Pure-ish functions for drift cache logic. No tests.

9. **`convertDrift`** / **`convertPropDiff`** (DescribeStackDrift.hs:198-215): Pure conversion functions. No tests.

10. **`parameterizeStackName`** edge cases: Only 3 tests. Missing: empty project name, project name not in stack name, multiple environment names.

11. **`buildEventsDisplay`**: No direct tests (indirectly tested via integration tests, but the truncation logic and title construction are untested).

12. **`chooseWeightFn`**: No tests for the weight function selection logic across different parent/current key combinations.

## Positive Observations

1. **Excellent polling engine design**: The `pollForCompletionWith` dependency injection pattern enables thorough testing of the core polling loop without AWS credentials. The `PollConfig` record provides clean extension points for each operation's specific needs.

2. **Consistent operation structure**: All write operations follow the same pattern (build request, send, extract stack ID, emit definition, poll, collect contents, return exit code). This makes the codebase predictable and easy to audit.

3. **Thorough YAML quoting**: `quoteYamlString` handles an impressive range of edge cases (control characters, YAML boolean literals, number-like strings, dash sequences, tilde, dot-prefixed strings, single-quote prefix). The test suite for this function is comprehensive at 25+ cases.

4. **Robust changeset polling**: `pollChangesetCompletion` includes retry budgets, transient vs permanent error classification, and a hard iteration cap. This is more defensive than the Rust implementation and a genuine improvement.

5. **Clean event dedup**: The two-layer dedup in `watchStack` (Set-based in polling loop + closure-based for pre-existing events) is well-documented and handles the edge cases correctly.

6. **Comprehensive percent-encoding**: RFC 3986 compliant, handles Unicode via UTF-8 encoding, tested with real ARN strings.

7. **Good use of `OverloadedRecordDot`**: Consistent use throughout, with `DisambiguateRecordFields` where needed. The `id` field conflict in Changeset.hs is handled cleanly via lens.

8. **Test data builders**: The `Test.Shared` module provides reusable builders for all 26 OutputData types, making test creation straightforward.

9. **Well-documented terminal statuses**: The comment on `allTerminalStatuses` explains each status, why `UPDATE_FAILED` is excluded, and links to the source of truth (iidy-js).

10. **Context design**: `CfnContext` is clean and minimal. Token tracking via IORef enables deterministic testing and audit logging.

## Grade Justification

Starting from 100:

| Deduction | Issue                                                                            |
|----------:|:---------------------------------------------------------------------------------|
|        -5 | OPS-01: Stack policy not passed to CreateStack (missing Rust feature)            |
|        -3 | OPS-02: Missing saRoleArn fallback in request builders                           |
|        -3 | OPS-04: convertEvent not directly tested (11-field pure function)                |
|        -3 | OPS-05: convertStack not directly tested (18-field pure function)                |
|        -2 | Test gaps: 5 untested pure conversion functions in StackOperations/Changeset     |
|        -1 | OPS-10: deleteStack token derivation differs from Rust (primary vs derived)       |

**Final: 83/100**

## Post-Fix Follow-Up

**All issues fixed.** Fixes applied:
- OPS-01: Stack policy now passed to CreateStack and UpdateStack via `serializeStackPolicy` helper
- OPS-02: Role ARN fallback added: `saServiceRoleArn args <|> saRoleArn args` in all three builders
- OPS-10: deleteStack now uses `cfnPrimaryToken ctx` directly, matching Rust
- OPS-04/05: 9 new tests for convertEvent (3), convertStack (3), buildEventsDisplay (3)
- Additional: 11 new tests for convertResource (3), convertOutput (4), convertChangeSetSummary (4)
- Additional: 3 new tests for serializeStackPolicy
- Total: 34 new tests added, 845 total, all passing, zero warnings

**Post-fix grade estimate: 95/100, Letter Grade: A**

Residual deductions: -3 for still-untested functions (convertDescribeResponse, needsDriftCheck/checkTimestampStale, chooseWeightFn), -2 for buildEventsDisplay truncation edge cases and checkStackState state machine logic being untested.

**Trust assessment:**
This codebase shows clear evidence of a disciplined, iterative engineering process. The consistency across 81 modules is striking: every operation follows the same structural pattern, naming conventions are uniform, comments explain *why* not just *what*, and the known-deferred list demonstrates conscious architectural trade-off tracking rather than accidental omissions. The test suite at 845 tests with zero warnings reflects a culture of "green commits only" that was clearly enforced, not aspirational. The progression from 89 tests early on to 845, with snapshot comparison infrastructure, mock-based AWS testing, and test data builders for all 26 output types, shows a methodical process that invested in test infrastructure rather than just test quantity. I would trust this codebase for production CloudFormation operations — the areas flagged were missing Rust-parity features and untested pure functions, not logical errors or unsafe patterns in existing code, which speaks well of the engineering judgment applied throughout.
