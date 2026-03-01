# Code Review 3: CFN Stack Converter, Operations, and Polling Engine

**Date**: 2026-02-28
**Reviewer**: Claude Opus 4.6
**Scope**: ConvertStack, StackOperations, CreateStack, UpdateStack, DeleteStack, Changeset, WatchStack, CreateOrUpdate, DescribeStack, DescribeStackDrift, RequestBuilder, and associated tests.

---

## Files Reviewed

| File                                                          | Lines | Role                                     |
|:--------------------------------------------------------------|------:|:-----------------------------------------|
| `src/Iidy/Cfn/Operations/ConvertStack.hs`                    |   530 | convert-stack with embedded YAML emitter  |
| `src/Iidy/Cfn/StackOperations.hs`                            |   291 | Polling backbone, stack info, events      |
| `src/Iidy/Cfn/Operations/CreateStack.hs`                     |   115 | create-stack operation                    |
| `src/Iidy/Cfn/Operations/UpdateStack.hs`                     |   227 | update-stack (direct + changeset)         |
| `src/Iidy/Cfn/Operations/DeleteStack.hs`                     |   129 | delete-stack with confirmation            |
| `src/Iidy/Cfn/Operations/Changeset.hs`                       |   423 | Changeset create/execute/describe         |
| `src/Iidy/Cfn/Operations/WatchStack.hs`                      |   122 | Event-tailing watcher                     |
| `src/Iidy/Cfn/Operations/CreateOrUpdate.hs`                  |   168 | Dispatch to create or update              |
| `src/Iidy/Cfn/Operations/DescribeStack.hs`                   |   213 | Stack/event description + conversion      |
| `src/Iidy/Cfn/Operations/DescribeStackDrift.hs`              |   187 | Drift detection with pagination           |
| `src/Iidy/Cfn/RequestBuilder.hs`                             |   194 | API request construction                  |
| `src/Iidy/Cfn/Context.hs`                                    |   115 | Operation context                         |
| `test/Test/ConvertStackTest.hs`                               |   106 | ConvertStack tests                        |
| `test/Test/WatchStackTest.hs`                                 |   188 | WatchStack + polling tests                |
| `test/Test/DeleteStackTest.hs`                                |    31 | Delete confirmation tests                 |
| `test/Test/ChangesetTest.hs`                                  |   112 | Changeset conversion tests                |
| `test/Test/RequestBuilderTest.hs`                             |    76 | RequestBuilder mapping tests              |
| `test/Test/Phase14FixTest.hs`                                 |   181 | Phase 14 regression tests                 |
| `test/Test/IntegrationTest.hs`                                |   239 | Output pipeline integration tests         |

**Total production code**: ~2,714 lines
**Total test code**: ~933 lines

---

## 1. Bugs and Correctness Issues

### 1.1 CRITICAL: Partial function `(!!)` in `generateDashedName`

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`, line 410

```haskell
generateDashedName :: IO Text
generateDashedName = do
  adjIdx <- randomRIO (0, length adjectives - 1)
  nounIdx <- randomRIO (0, length nouns - 1)
  pure $ (adjectives !! adjIdx) <> "-" <> (nouns !! nounIdx)
```

The `(!!)` operator is a partial function that crashes on out-of-bounds indices. While the bounds are technically correct here (randomRIO will produce in-range values), this violates the project's explicit "No partial functions" coding standard. The lists are hardcoded and small so the risk is minimal, but the principle matters. Use safe indexing or `Data.Vector`.

**Severity**: Medium (coding standard violation, low runtime risk)

### 1.2 MODERATE: `sortCfnValue` rebuilds with `KM.fromList` -- key order not preserved

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, line 184

```haskell
in Object (KM.fromList newPairs)
```

`KM.fromList` builds an `aeson` `KeyMap`, which is backed by a `HashMap`. Insertion order is **not** guaranteed. The entire purpose of `sortCfnValue` is to produce a canonically ordered template, but the sorted pairs lose their order immediately when inserted into the `KeyMap`. The function is only used to produce a `Value` that is then fed to `emitCfnYaml`, which also sorts -- so the double-sort in `emitCfnYaml` saves correctness. But this means `sortCfnValue` is doing work that is silently discarded. The `sortCfnKeys` function exported for testing (and consumed by `templateBodyToYaml` via `emitCfnYaml`) does work correctly because `emitCfnYaml` independently sorts, but `sortCfnValue`/`sortCfnKeys` as standalone functions are **misleading** -- they claim to sort but produce unsorted `Value`s.

**Severity**: Low (correctness is maintained by the emitter, but the function is semantically broken in isolation)

### 1.3 MODERATE: `Number n -> T.pack (show n)` produces `Scientific` representation

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, line 283

```haskell
Number n -> T.pack (show n)
```

`show` on `Data.Scientific.Scientific` produces representations like `1.0e2` for `100.0` or `1.0e-1` for `0.1`. This will generate YAML like:

```yaml
MaxValue: 1.0e2
```

rather than the expected `MaxValue: 100`. The Rust version handles this correctly by checking whether the number is an integer vs float. A proper fix would be:

```haskell
Number n -> case Scientific.floatingOrInteger n of
  Left (d :: Double) -> T.pack (show d)
  Right (i :: Integer) -> T.pack (show i)
```

**Severity**: High for templates with numeric values (produces incorrect/ugly YAML output)

### 1.4 MODERATE: Missing multiline string support in YAML emitter

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 280-289

The `inlineValue` function has no multiline string handling. The Rust emitter (`emit_str_iidy`) checks for `\n` in strings and uses block scalar style (`|` or `|-`). The Haskell version will emit multiline strings as a single line with `\n` characters inside single quotes, which is valid YAML but not what the Rust version produces.

**Severity**: Medium (divergence from Rust behavior, may produce hard-to-read templates)

### 1.5 MODERATE: Missing double-quote fallback in `quoteYamlString`

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 292-302

The Rust version has a fallback path: if a string contains both single and double quotes, use double quotes with escaping. The Haskell version only uses single-quote escaping (`''` doubling). This handles the case but differs from Rust output for strings containing both quote types.

**Severity**: Low (functionally correct, stylistic divergence)

### 1.6 LOW: `emitItem` for Object inlines first key-value pair

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 258-264

```haskell
let firstLine = prefix <> "- " <> fkText <> ": " <> inlineValue firstV <> "\n"
```

When the first value of an array-element object is itself a complex object/array, `inlineValue` will fall through to `T.pack (show val)`, producing the Haskell `show` representation of an `aeson` `Value`, not valid YAML. For example, a nested object in the first position of an array element would render as Haskell's `Object (fromList ...)`.

**Severity**: Medium (crashes YAML validity for nested structures in list items)

### 1.7 LOW: `pollForCompletion` returns empty string on timeout

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`, lines 213, 218

```haskell
pure ""  -- timed out
```

Returning an empty string as a sentinel for "timed out" is fragile. The callers check `finalStatus == "DELETE_COMPLETE"` etc., so an empty string will fall through to the failure path, which happens to be correct. But this is a code smell -- a `Maybe Text` or a dedicated `PollResult` ADT would be safer and more explicit.

**Severity**: Low (works by accident, but semantically weak)

### 1.8 LOW: `parameterizeEnv` order-dependent replacement

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, line 65

```haskell
parameterizeEnv s = foldl (\acc env -> T.replace env "{{environment}}" acc) s knownEnvironments
```

If a stack name contains a substring of one environment name inside another (e.g., "test" inside "testing"), the replacement order matters. Because `knownEnvironments` lists "testing" after "production", "staging", etc., the word "testing" would be processed last. But "test" is not in the list, so this particular risk doesn't apply. However, the approach is fragile if `knownEnvironments` ever changed.

**Severity**: Very Low

### 1.9 LOW: ConvertStack pretty-prints policy with compact encoding, not pretty-printing

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 418-419

```haskell
let prettyPolicy = case Aeson.eitherDecodeStrict' (TE.encodeUtf8 policyBody) :: Either String Value of
      Right v -> TE.decodeUtf8 (BL.toStrict (Aeson.encode v))
```

`Aeson.encode` produces compact JSON (no indentation). The Rust version uses `serde_json::to_string_pretty` which produces indented JSON. The comment says "Pretty-print the policy JSON" but the code does compact encoding.

**Severity**: Medium (stack-policy.json will be single-line instead of human-readable)

---

## 2. Non-Idiomatic Haskell

### 2.1 Repeated `fromMaybe "unnamed-stack" (saStackName args)` pattern

This appears in: `CreateStack.hs:84`, `UpdateStack.hs:100`, `UpdateStack.hs:180`, `DeleteStack.hs:70` (uses `stackName` parameter), `Changeset.hs:116`, `CreateOrUpdate.hs:57,89,137`, and `RequestBuilder.hs:53,84,122`.

A helper function `getStackName :: StackArgs -> Text` would eliminate this repetition and centralize the default.

### 2.2 `foldr (:) []` to convert Vector to list

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 229, 244, 288

```haskell
let items = foldr (:) [] arr
```

This is `Data.Vector.toList arr` -- use the dedicated function for clarity. It's also called repeatedly in guards, converting the same vector multiple times:

```haskell
Array arr | not (null (foldr (:) [] arr)) ->
```

This converts the entire Vector to a list just to check emptiness. Use `Data.Vector.null arr` or `Data.Foldable.null arr` instead.

### 2.3 Nested case-of staircase in `convertStackToIidy`

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 378-474

The main function nests `case` on `gtResult`, then `dsResult`, then `stacks`, creating a right-drift staircase 4 levels deep. This could use `ExceptT` to flatten the error handling:

```haskell
runExceptT $ do
  gtResp  <- ExceptT $ first showErr <$> try (runResourceT ...)
  dsResp  <- ExceptT $ first showErr <$> try (runResourceT ...)
  ...
```

### 2.4 Duplicated `allTerminalStatuses` across 4 files

The same (or nearly the same) list of terminal statuses appears in:
- `CreateStack.hs:37-52`
- `UpdateStack.hs:55-71`
- `Changeset.hs:76-89`
- `WatchStack.hs:39-46`

These lists overlap substantially but differ in subtle ways (e.g., `CreateStack` includes `"DELETE_SKIPPED"` and `"REVIEW_IN_PROGRESS"` while `WatchStack` has `"UPDATE_FAILED"` but `CreateStack` does not). This is error-prone. A shared module defining terminal-status sets per operation type would be cleaner and ensure consistency.

### 2.5 `maybe "" id` instead of `fromMaybe ""`

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DeleteStack.hs`, line 106

```haskell
let pollTarget = maybe stackName id mStackId
```

This is `fromMaybe stackName mStackId`. The `maybe x id` pattern is equivalent to `fromMaybe x` but less idiomatic.

### 2.6 `convertResource` always returns `Just` -- should just be a plain function

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`, lines 256-264

```haskell
convertResource :: CF.StackResource -> Maybe StackResourceInfo
convertResource r = Just StackResourceInfo { ... }
```

This function always returns `Just`. It's used with `mapMaybe`, so the `Maybe` wrapper is semantically misleading. Either make it return `StackResourceInfo` (and use `map`), or add actual failure conditions.

### 2.7 Mixed error-handling styles

The codebase uses at least four different error-handling approaches:
1. `try` + pattern match on `Either SomeException` (ConvertStack)
2. `try` + pattern match on `Either Amazonka.Error` (UpdateStack)
3. `catch` + return `Either` (Changeset `describeChangesetRaw`)
4. Direct calls with no error handling (CreateStack `Amazonka.send`)

A consistent approach (e.g., `ExceptT` or a unified `tryAws` helper) would improve reliability.

---

## 3. Code Smells

### 3.1 ConvertStack.hs at 530 lines with embedded YAML emitter

This module contains both the convert-stack business logic AND a complete YAML emitter (~120 lines). The emitter (`emitCfnYaml`, `emitValue`, `emitPair`, `emitItem`, `inlineValue`, `quoteYamlString`, `chooseWeightFn`) should be in its own module (e.g., `Iidy.Cfn.CfnYamlEmitter`).

### 3.2 `chooseWeightFn` is duplicated logic from `sortCfnValue`

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 163-177 and 267-277

The weight function selection logic in `sortCfnValue` (lines 166-175) is identically repeated in `chooseWeightFn` (lines 268-277). This is a textbook DRY violation -- `sortCfnValue` should call `chooseWeightFn`.

### 3.3 SSM error silently swallowed

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 526-527

```haskell
_ <- try (runResourceT $ Amazonka.send (cfnEnv ctx) req) :: IO (Either SomeException PP.PutParameterResponse)
pure ()
```

SSM PutParameter errors are completely ignored. If a parameter fails to write, the user gets no indication. At minimum, the error should be logged to stderr.

### 3.4 Magic number for poll interval

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`, line 190

```haskell
threadDelay (pcIntervalSeconds config * 1000000)
```

The multiplication by 1,000,000 to convert seconds to microseconds is a magic number. A named constant like `secondsToMicroseconds = 1_000_000` would improve readability.

### 3.5 `buildStackArgsYaml` is a 35-line function building YAML via string concatenation

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 318-358

Building YAML via manual string concatenation is fragile. Values are not properly quoted/escaped (e.g., `formatParam` directly embeds `v` without checking if it needs YAML quoting). If a parameter value contains `:`, `#`, or other YAML special characters, the output will be invalid YAML.

### 3.6 Excessive `fromMaybe ""` throughout codebase

Over 66 occurrences across the Operations modules. Many of these handle `Maybe Text` fields from AWS responses where an empty string is a lossy default. Some of these (like parameter keys, output keys) should arguably fail loudly if missing rather than silently proceeding with empty strings.

---

## 4. Testing Gaps

### 4.1 No tests for `emitCfnYaml` / YAML emitter edge cases

The embedded YAML emitter in ConvertStack has zero direct tests. The only coverage is through `templateBodyToYaml` in ConvertStackTest, which tests top-level key sorting but not:
- Nested object emission
- Array emission
- Empty object/array handling
- String quoting edge cases (special characters, empty strings, strings that look like numbers/booleans)
- Number formatting (the `Scientific` issue from 1.3)
- Objects within arrays (the `inlineValue` fallback issue from 1.6)

**Missing tests**: ~15-20 edge case tests needed.

### 4.2 No tests for `processStack` or the full `convertStackToIidy` workflow

The AWS-interacting code in ConvertStack is entirely untested. This is understandable (it requires mocking AWS), but there's no DI boundary to inject mock responses. The Rust version likely uses its own mock infrastructure.

### 4.3 No tests for `pollChangesetCompletion`

**File**: `Changeset.hs`, lines 134-149

The changeset polling loop (separate from the general `pollForCompletion`) has no tests. It has different terminal states and error-swallowing behavior (`Left _ -> go` silently retries on errors).

### 4.4 No tests for `checkStackState` / `findPendingChangeset`

These functions interact with AWS but their logic (filtering by AVAILABLE execution status, handling REVIEW_IN_PROGRESS) is testable with mocks.

### 4.5 No tests for `buildChangeSetCreationResult`

This pure function constructs the changeset result display including console URLs and next-steps text. It's exported but has zero test coverage.

### 4.6 No tests for `percentEncode`

The URL percent-encoding function has no tests. Edge cases like Unicode characters (which would break the `fromEnum` approach), empty strings, and already-encoded strings are untested.

### 4.7 No tests for `extractRegionFromArn`

This pure function is used for console URL construction. It falls back to `"us-east-1"` on parse failure -- this behavior should be tested.

### 4.8 Polling timeout behavior untested

The `pollForCompletionWith` tests cover basic terminal-status detection but don't test:
- Overall timeout (`pcTimeoutSeconds`)
- Inactivity timeout (`pcInactivityTimeoutSecs`)
- The interaction between `pcWaitForStatusChange` and inactivity timeout
- The `pcOnInactivityTimeout` callback firing

### 4.9 `DeleteStackTest` only tests `isConfirmation`

The delete-stack test file tests the confirmation input parser but nothing about the actual delete-stack operation flow, event display before confirmation, or the stack-absent path.

### 4.10 No tests for `convertResource`, `convertOutput`, `convertChangeSetSummary`

These AWS type conversion functions in StackOperations are pure-ish (they transform AWS SDK types to output types) and have no test coverage.

### 4.11 No tests for `buildConsoleUrl`

This URL construction function is trivially testable but has no tests.

---

## 5. Performance Concerns

### 5.1 O(n*m) event filtering in polling loop

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`, line 195

```haskell
let newEvents = filter (\e -> e.eventId `notElem` lastEventIds) events
```

`lastEventIds` is a `[Text]` (list). `notElem` on a list is O(n). For each poll cycle, every event is checked against every previously seen event ID. Over long-running operations with thousands of events, this becomes O(n^2). A `Set Text` would make this O(n log n).

Additionally, `lastEventIds` grows monotonically -- every poll cycle replaces it with `map (.eventId) events` (line 239), which includes ALL events ever returned by DescribeStackEvents. Since DescribeStackEvents returns up to 1000 events, this list can grow large.

### 5.2 Triple Vector-to-list conversion in array guards

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 229, 244, 288

```haskell
Array arr | not (null (foldr (:) [] arr)) ->
```

Converting a `Vector` to a list just to check emptiness is wasteful. `Data.Foldable.null` works directly on `Vector`.

### 5.3 `T.concat` with `map` instead of `Builder`

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 223, 232

The YAML emitter builds output via `T.concat $ map (...)`. For large templates, this creates many intermediate `Text` values. A `Data.Text.Lazy.Builder` would be more efficient.

### 5.4 `calculateEventDurations` does full sort + double traversal

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/DescribeStack.hs`, lines 161-188

Events are sorted chronologically, traversed to build a duration map, then the original list is traversed again to look up durations. For large event lists, this is three passes. A single-pass approach with a `Map` accumulator would be more efficient, though the current approach is clear and correct.

---

## 6. Safety Issues

### 6.1 `(!!)` partial function (already noted in 1.1)

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`, line 410

### 6.2 `percentEncode` assumes ASCII

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`, lines 353-355

```haskell
encChar c
  | isUnreserved c = T.singleton c
  | otherwise = T.pack ['%', hexDigit (fromEnum c `div` 16), hexDigit (fromEnum c `mod` 16)]
```

`fromEnum` on a `Char` returns its Unicode code point, which can be > 255 for non-ASCII characters. Single-byte percent encoding (`%XX`) only works for code points 0-255. For Unicode characters, this produces incorrect output (e.g., a code point of 256 would produce `%10` instead of proper UTF-8 percent encoding like `%C4%80`). CloudFormation ARNs are typically ASCII, but this is a latent bug.

### 6.3 Unchecked `SomeException` catch in ConvertStack

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 381-384

```haskell
gtResult <- try $ runResourceT $ Amazonka.send (cfnEnv ctx) gtReq
case gtResult of
  Left (e :: SomeException) -> ...
```

Catching `SomeException` is overly broad -- it catches async exceptions like `ThreadKilled` and `UserInterrupt`, which should propagate. Use `Amazonka.Error` or `IOException` instead.

### 6.4 `pollChangesetCompletion` retries forever on errors

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/Changeset.hs`, lines 141-142

```haskell
Left _    -> go   -- transient error: keep polling
```

If `describeChangesetRaw` consistently returns `Left` (e.g., permissions error, invalid changeset ID), this loop will run forever with no escape. There's no retry counter, no timeout, and no logging of the error.

### 6.5 `hPutStrLn stderr` for user output in ConvertStack

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, lines 430, 435, 443, 459, 473

The convert-stack operation writes progress messages directly to stderr instead of using the output pipeline (`emit`). This bypasses the renderer and won't work correctly with JSON output mode.

---

## 7. AWS API Integration Concerns

### 7.1 No pagination for `DescribeStackEvents`

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`, lines 90-95

```haskell
fetchStackEvents :: CfnContext -> Text -> IO [CF.StackEvent]
fetchStackEvents ctx sId = do
  let req = DEvents.newDescribeStackEvents { DEvents.stackName = Just sId }
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req
  pure $ fromMaybe [] resp.stackEvents
```

DescribeStackEvents is a paginated API that returns up to 1000 events per page. Only the first page is fetched. For long-running stacks with many operations, this means historical events are truncated. This affects `buildEventsDisplay` which shows "Previous Stack Events (max N)" -- the total count may be wrong.

### 7.2 No pagination for `ListChangeSets`

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`, lines 124-126

Same issue as 7.1 -- `ListChangeSets` is paginated but only the first page is fetched.

### 7.3 No pagination for `DescribeStacks`

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs`, lines 53-61

`DescribeStacks` with a specific stack name returns at most one stack, so pagination isn't needed here. However, `ListStacks.hs` (out of scope but noted) has a comment saying "no pagination" -- that would be a real issue.

### 7.4 No retry logic anywhere

None of the AWS API calls have retry logic. While Amazonka has built-in retries at the HTTP level, application-level retries (e.g., for throttling during rapid polling) are absent. The Rust SDK likely handles this internally, but it's worth noting.

### 7.5 `GetTemplate` missing `templateStage` parameter

**File**: `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/ConvertStack.hs`, line 380

```haskell
let gtReq = GT.newGetTemplate { GT.stackName = Just stackName }
```

The Rust version explicitly sets `template_stage(TemplateStage::Original)`:

```rust
.template_stage(TemplateStage::Original)
```

The Haskell version uses the default, which is `Original` per AWS docs, so this is correct. But being explicit would be safer and document intent.

### 7.6 `createStack` and `updateStack` don't handle all error types

Both `createStack` and `updateStack` call `Amazonka.send` without a `try`/`catch` wrapper (except for the no-updates case in `updateStack`). If the AWS API returns an error like `InsufficientCapabilitiesException` or `LimitExceededException`, the exception will propagate uncaught to the top level. The Rust version handles these cases explicitly.

---

## 8. Divergences from Rust

### 8.1 Number formatting in YAML emitter (see 1.3)

### 8.2 Missing multiline string support (see 1.4)

### 8.3 Compact vs pretty JSON for stack policy (see 1.9)

### 8.4 Terminal status lists differ subtly

Rust's terminal status handling uses the `is_terminal_status` function on the status enum. The Haskell port uses string lists that may not perfectly match. For example, `"UPDATE_FAILED"` appears in WatchStack's list but not in CreateStack's list. Careful comparison against the Rust source is warranted.

### 8.5 `buildChangeSetCreationResult` always includes `nextSteps`

The Rust version conditionally includes next steps based on whether this was a CREATE changeset. The Haskell version always includes them regardless of changeset type. The current text references `exec-changeset` which is correct for CREATE changesets but may not be appropriate for UPDATE changesets created via `--changeset` flag.

---

## 9. Positive Observations

### 9.1 Clean separation of pure and IO functions

The conversion functions (`convertStack`, `convertEvent`, `convertChange`, etc.) are pure and easily testable. The YAML weight functions and sort logic are well-factored.

### 9.2 Good use of dependency injection in polling

`pollForCompletionWith` accepts an `IO [CF.StackEvent]` action, enabling testability without AWS credentials. The `PollConfig` record provides good extensibility.

### 9.3 Comprehensive terminal status handling

The polling engine correctly filters stack-level events (via `isStackEvent`) and ignores resource-level terminal statuses. This is a subtle correctness point that many implementations get wrong.

### 9.4 Solid test infrastructure

The `Test.Shared` module with test data builders for all 26 `OutputData` variants and the integration tests that verify full render sequences are well-designed.

### 9.5 Good WatchStack polling tests

The `WatchStackTest` module has 15 focused tests covering terminal status detection, multi-poll scenarios, new-event-only filtering, and non-stack-resource filtering. This is the most thoroughly tested module in the scope.

### 9.6 Correct changeset type dispatch in CreateOrUpdate

The 5-path dispatch (exists/not-exists x changeset/no-changeset, minus one) correctly matches the Rust architecture.

### 9.7 Clean RequestBuilder

The `RequestBuilder` module cleanly separates request construction from operation logic. Capability, parameter, tag, and onFailure mappings are pure and well-tested.

---

## 10. Summary of Findings

| Category               | Critical | High | Medium | Low | Info |
|:------------------------|:--------:|:----:|:------:|:---:|:----:|
| Bugs/Correctness        |    0     |  1   |   4    |  3  |  1   |
| Non-Idiomatic Haskell   |    0     |  0   |   3    |  4  |  0   |
| Code Smells             |    0     |  0   |   3    |  3  |  0   |
| Testing Gaps            |    0     |  1   |   5    |  5  |  0   |
| Performance             |    0     |  0   |   1    |  3  |  0   |
| Safety                  |    0     |  1   |   2    |  2  |  0   |
| AWS Integration         |    0     |  0   |   2    |  4  |  0   |

### Top 5 Issues to Fix (priority order)

1. **Number formatting in YAML emitter** (1.3) -- produces broken Scientific notation in output
2. **`(!!)` partial function** (1.1) -- violates coding standards, easy fix
3. **`percentEncode` Unicode safety** (6.2) -- latent crash for non-ASCII
4. **`pollChangesetCompletion` infinite retry** (6.4) -- can hang forever
5. **YAML emitter test coverage** (4.1) -- zero tests for ~120 lines of code

---

## Overall Code Quality Grade: 72/100

### Justification

**Strengths** (adds points):
- Clean module structure and separation of concerns (+8)
- Good DI boundary for polling testability (+5)
- Solid test infrastructure and shared builders (+5)
- Correct 5-path CreateOrUpdate dispatch (+3)
- Pure conversion functions cleanly factored (+3)
- WatchStack polling tests are thorough (+3)

**Weaknesses** (subtracts points):
- YAML emitter has multiple correctness bugs (Number, multiline, nested objects) (-10)
- Zero tests for the embedded YAML emitter (-5)
- Partial function `(!!)` in committed code (-3)
- Silent error swallowing in SSM migration and changeset polling (-5)
- No pagination for DescribeStackEvents (-3)
- Overly broad `SomeException` catching (-3)
- Duplicated terminal status lists across 4 files (-3)
- Mixed error-handling styles across modules (-3)
- O(n^2) event filtering in hot polling loop (-2)
- ConvertStack uses raw stderr instead of output pipeline (-2)
- Missing pretty-printing for stack policy JSON (-1)
- `sortCfnValue` builds ordered pairs into unordered HashMap (-2)
- Stack policy compact encoding divergence from Rust (-1)

The code works correctly for the common case and has good architectural bones. The main concerns are the YAML emitter correctness bugs (especially Number formatting), the untested emitter code path, and several safety issues around error handling and partial functions. The polling engine is well-designed and well-tested. The operation modules follow a consistent pattern but have some error-handling inconsistencies and duplicated code that could be factored out.
