# Code Review Round 2: Interactive Renderer Subsystem

**Date**: 2026-03-01
**Round**: 2 of 3
**Reviewer**: Claude Opus 4.6 (independent)
**Scope**: 16 files (10 production, 6 test)

| File                                             | LOC  |
|:-------------------------------------------------|-----:|
| src/Iidy/Output/Renderers/Interactive.hs         | 1026 |
| src/Iidy/Output/Types.hs                         |  456 |
| src/Iidy/Output/Color.hs                         |  235 |
| src/Iidy/Output/Spinner.hs                       |  117 |
| src/Iidy/Output/Manager.hs                       |   71 |
| src/Iidy/Output/Terminal.hs                      |   46 |
| src/Iidy/Output/Theme.hs                         |   38 |
| src/Iidy/Output/Renderer.hs                      |   10 |
| src/Iidy/Output/Status.hs                        |   45 |
| src/Iidy/Output/Renderers/Json.hs                |  521 |
| test/Test/RendererTest.hs                         |  224 |
| test/Test/RendererOutputTest.hs                   |  145 |
| test/Test/JsonRendererTest.hs                     |  332 |
| test/Test/IntegrationTest.hs                      |  238 |
| test/Test/ErrorColorTest.hs                       |  104 |
| test/Test/Shared.hs                               |  472 |

## Grade: 74/100

## Summary

The interactive renderer subsystem is architecturally clean in its decomposition: types, color, theme, spinner, terminal detection, and renderers are well-separated into focused modules. The `OutputData` sum type provides a solid, type-safe dispatch mechanism and the test data builders in `Test.Shared` are exemplary. However, there are real bugs -- a dead-code `encodeValue` function that silently ignores pretty-printing, a partial function `NE.fromList` in production code, race conditions in IORef-based concurrency, and the `Interactive.hs` module at 1026 LOC is double the project's 300-500 LOC ceiling. There is also meaningful test coverage gap: no tests verify actual rendered output strings from `renderOutputData`, only that it does not crash.

## Issues Found

### 1.1: `encodeValue` ignores `joPrettyPrint` -- both branches identical (Severity: Major)
**File**: src/Iidy/Output/Renderers/Json.hs:163-167
**What**: The function claims to pretty-print when `joPrettyPrint opts` is `True`, but both branches call `Aeson.encode val` (compact). The comment `-- compact for now` on the `True` branch confirms this was intentionally left broken, but calling code uses `joPrettyPrint` in `outputRawJson` (line 152) where `Pretty.encodePretty` is properly used. The inconsistency means any consumer of `encodeValue` with pretty-printing enabled gets compact output silently.
**Fix**: Either use `Pretty.encodePretty val` in the `True` branch, or remove the `joPrettyPrint` check and the `aeson-pretty` import to avoid giving callers the false impression that the option works.

### 1.2: `NE.fromList` is a partial function in production code (Severity: Major)
**File**: src/Iidy/Output/Renderers/Interactive.hs:877
**What**: `NE.fromList events` will throw an error if `events` is empty. While the surrounding `unless (null events)` guard on line 865 protects it today, `NE.fromList` is explicitly listed as a partial function. If someone refactors the guard or extracts this logic, the crash surfaces. The project standard says "no partial functions".
**Fix**: Use `NE.nonEmpty events` pattern match instead, or use `Data.List.last` (which is itself partial -- better to use a safe last via pattern matching or `lastMay` from `safe`). Simplest fix: `case NE.nonEmpty events of { Just ne -> ... NE.last ne ...; Nothing -> pure () }`.

### 1.3: Race conditions on IORef-based spinner state (Severity: Major)
**File**: src/Iidy/Output/Renderers/Interactive.hs:183-290
**What**: The spinner subsystem uses `IORef` values that are read and written from multiple threads (main thread, spinner tick thread, timing thread) without any atomicity guarantees. Specifically:
- `irTimingState` is read by `timingLoop` (background thread, line 260) and written by `stopTimingTask` (main thread, line 280) and `updateLastEventTime` (main thread, line 288). A read-modify-write sequence like lines 285-288 is a classic TOCTOU race.
- `irSpinner` is read by `renderNewStackEvents` and written by `stopSpinner`/`startSpinner`.
- `startSpinner` calls `stopSpinner` then creates a new spinner, but between the stop and start, the background timing thread might still access stale refs.

While `mask_` protects `stopSpinner` and `stopTimingTask` from async exceptions, it does not make the IORef operations atomic across threads.
**Fix**: Use `MVar` or `TVar` (from STM) instead of `IORef` for shared mutable state accessed by multiple threads. Alternatively, use `atomicModifyIORef'` for the read-modify-write patterns and document that IORef writes from the main thread are safe because background threads only read.

### 1.4: `V.head` is a partial function in test code (Severity: Minor)
**File**: test/Test/RendererOutputTest.hs:141
**What**: `V.head arr` will crash on an empty `Vector`. The test already checked `V.length arr == 1` on line 140, so this is safe in practice, but using a partial function in tests still sets a bad example.
**Fix**: Use `V.headM arr` or pattern match with `V.!? 0`.

### 1.5: `error` calls in test code (Severity: Minor)
**File**: test/Test/ErrorColorTest.hs:49, 57
**What**: Uses `error "expected non-empty output"` and `error "expected 'available variables' line"` in pattern match fallbacks. These are partial -- if they fire, the test gets an unhelpful crash rather than a proper test failure.
**Fix**: Replace with `assertFailure "..."` calls which produce proper test failure messages.

### 1.6: Interactive.hs exceeds module size limit at 1026 LOC (Severity: Major)
**File**: src/Iidy/Output/Renderers/Interactive.hs
**What**: At 1026 lines, this file is more than double the project's 300-500 LOC guideline. It contains formatting helpers, spinner management, timing logic, and 20+ individual render functions. The file is hard to navigate.
**Fix**: Split into at least 3 modules:
- `Iidy.Output.Renderers.Interactive.Formatting` -- `formatSectionHeading`, `formatSectionEntry`, `padRight`, `prettyFormatTags`, `prettyFormatParameters`, `calcPadding`, `wrapText`, `boolText`, `detectEnvironment`, `firstJust`
- `Iidy.Output.Renderers.Interactive.SpinnerMgmt` -- `startSpinner`, `stopSpinner`, `startTimingTask`, `stopTimingTask`, `timingLoop`, `formatTimingText`, `spinnerTickLoop`
- `Iidy.Output.Renderers.Interactive` -- the renderer type, dispatch, and render methods

### 1.7: `prettyFormatSmallMap` is dead code alias (Severity: Minor)
**File**: src/Iidy/Output/Renderers/Interactive.hs:449-450
**What**: `prettyFormatSmallMap` is defined as `prettyFormatSmallMap = prettyFormatParameters` and used only once (line 475). It adds a layer of indirection with no semantic difference.
**Fix**: Inline `prettyFormatParameters` at the call site and delete `prettyFormatSmallMap`.

### 1.8: `firstJust` reimplements `Data.Foldable.asum` (Severity: Minor)
**File**: src/Iidy/Output/Renderers/Interactive.hs:453-457
**What**: `firstJust f xs` is equivalent to `Data.Foldable.asum (map f xs)` or `listToMaybe (mapMaybe f xs)` from base. Reimplementing standard library functions adds maintenance burden.
**Fix**: Replace with `asum (map (\k -> (k,) <$> Map.lookup k tags) envKeys)` from `Data.Foldable`.

### 1.9: `prettyFormatTags` truncation can produce negative `take` count (Severity: Minor)
**File**: src/Iidy/Output/Renderers/Interactive.hs:436-438
**What**: When `maxTags` is `Just 0` and `envFormatted` is non-empty (length 1), `remaining` becomes `-1`, and `take (remaining - 1)` is `take (-2)`. In Haskell, `take` with a negative argument returns `[]`, so this does not crash, but the result is `["Environment=prod", "..."]` which is 2 items when the caller asked for 0 max. The `"..."` marker is always appended when truncating regardless of whether it fits within the budget.
**Fix**: Add a guard: `if remaining <= 0 then [] else if remaining < length otherFormatted then take (remaining - 1) otherFormatted <> ["..."] else otherFormatted`.

### 1.10: Spinner `!!` indexing is unnecessary (Severity: Minor)
**File**: src/Iidy/Output/Spinner.hs:60, 76
**What**: `NE.toList frames !! (frame \`mod\` NE.length frames)` converts a `NonEmpty` to a list, then indexes. While safe due to the `mod`, this is O(n) and uses `!!` which is a partial function by reputation. The `NonEmpty` module provides direct cycling via `NE.cycle`.
**Fix**: Use a cycling zipper or `NE.toList frames !! ...` is admittedly safe here due to `mod`, but cleaner alternatives exist: define a helper `cycleIndex ne i = NE.toList ne !! (i \`mod\` NE.length ne)` with a comment, or use `Data.List.cycle (NE.toList frames) !! frame` (also O(n) but more idiomatic).

### 1.11: `spinnerTickLoop` is infinite recursion without exception handling (Severity: Minor)
**File**: src/Iidy/Output/Renderers/Interactive.hs:204-208
**What**: `spinnerTickLoop` recurses infinitely. If `spinnerRender` throws an exception (e.g., broken pipe on stdout), the exception propagates uncaught to the forked thread, which silently dies. The main thread has no way to know the spinner stopped.
**Fix**: Wrap the loop body in `try @SomeException` and either log or re-render on error, or document that thread death is acceptable and the spinner will be cleaned up by `stopSpinner`.

### 1.12: `killThread` can silently fail if thread already dead (Severity: Minor)
**File**: src/Iidy/Output/Renderers/Interactive.hs:218, 277
**What**: `killThread tid` throws `ThreadKilled` to the target thread. If the thread already terminated (e.g., due to an exception in `spinnerTickLoop`), this is a no-op, which is fine. However, there is no exception handling around the `killThread` call itself -- if the target thread installed an exception handler that blocks `ThreadKilled`, `killThread` would block the calling thread. This is unlikely in practice but worth noting.
**Fix**: No action strictly needed; the current usage is standard Haskell concurrent cleanup.

### 1.13: `newInteractiveRendererWithHandles` calls `detectCapabilities` even when options override all values (Severity: Minor)
**File**: src/Iidy/Output/Renderers/Interactive.hs:138-159
**What**: `detectCapabilities` queries `stdout` for TTY status and reads environment variables. When `ioEnableAnsi` is `False` and `ioTerminalWidth` is `Just w`, the capabilities are partially wasted. More importantly, `detectCapabilities` always checks `stdout`, but the renderer might be configured with a different handle (`hOut`).
**Fix**: Either pass the output handle to `detectCapabilities`, or restructure so that the caller can provide pre-computed capabilities. This matters for tests where `hOut` is `/dev/null` but `detectCapabilities` still checks `stdout`.

### 1.14: `colorizeResourceStatus` in Color.hs and `categorizeStatus` in Status.hs are inconsistent (Severity: Minor)
**File**: src/Iidy/Output/Color.hs:221-227, src/Iidy/Output/Status.hs:23-30
**What**: `colorizeResourceStatus` uses `T.isInfixOf` to detect status categories (e.g., `T.isInfixOf "IN_PROGRESS" status`), while `categorizeStatus` uses `T.isSuffixOf` (e.g., `T.isSuffixOf "_IN_PROGRESS" status`). These will disagree on a hypothetical status like `"IN_PROGRESS_CLEANUP"`. Additionally, `colorizeResourceStatus` checks for `DELETE_SKIPPED` with exact equality, while `categorizeStatus` also does. But `colorizeResourceStatus` does not handle `REVIEW_IN_PROGRESS` as a special case the way `categorizeStatus` does. The color module should delegate to the status module to avoid maintaining two parallel classification systems.
**Fix**: Rewrite `colorizeResourceStatus` to use `categorizeStatus` internally: `colorizeResourceStatus theme status = case categorizeStatus status of StatusInProgress -> colorize theme (thWarning theme) status; ...`.

### 1.15: Test `!!` indexing is partial and fragile (Severity: Minor)
**File**: test/Test/RendererTest.hs:154-155, 175, 189-190
**What**: Tests use `result !! 0`, `result !! 1`, `result !! 2`, `result !! 3` without bounds checking. If `calculateEventDurations` returned fewer elements than expected, the test would crash with an unhelpful index error rather than a test failure.
**Fix**: Use pattern matching: `case result of [r0, r1] -> do ...; _ -> assertFailure "expected 2 results"`.

### 1.16: `StackEvent.seTimestamp` is `Maybe UTCTime` but events without timestamps are common edge case (Severity: Minor)
**File**: src/Iidy/Output/Types.hs:127
**What**: The `seTimestamp` field is `Maybe UTCTime`, which means sorting by timestamp (`sortBy (comparing (seTimestamp . sewEvent))` in `renderStackEvents` line 565) will place `Nothing` timestamps first (since `Nothing < Just _` in the `Ord` for `Maybe`). This might cause events without timestamps to appear before events with timestamps, which may not match the desired display order. The Rust source likely always has timestamps from AWS.
**Fix**: Either make the field non-optional (since AWS always provides timestamps), or use `sortBy (comparing (fromMaybe maxBound . seTimestamp . sewEvent))` to push timestamp-less events to the end.

### 1.17: `unlines` usage in IntegrationTest.hs operates on `[String]` not `[Text]` (Severity: Minor)
**File**: test/Test/IntegrationTest.hs:56, 68, 164
**What**: `unlines [tag <> ": " <> show ex | ...]` uses `Prelude.unlines` on `String` values. This is correct since `assertFailure` takes `String`, but the list comprehension uses `show` on `SomeException` (producing `String`) concatenated with `String` literals using `Prelude.(<>)`. This works but is inconsistent with the project's preference for `Text`.
**Fix**: No fix strictly needed -- `assertFailure` takes `String` so `String` operations are appropriate here.

### 1.18: `outputSequenceTests` duplicates test data from `interactiveRendererIntegrationTests` (Severity: Minor)
**File**: test/Test/IntegrationTest.hs:180-237 vs 70-113
**What**: The output sequence tests reconstruct the exact same sequences that are used in the integration renderer tests (create-stack, describe-stack, delete-stack). The sequences are written out again rather than being shared constants.
**Fix**: Extract the sequences into named constants in `Test.Shared` and reuse them.

### 1.19: `JsonRenderer` is not a newtype and exports constructor (Severity: Minor)
**File**: src/Iidy/Output/Renderers/Json.hs:77-81
**What**: `JsonRenderer` exposes its internals via the constructor in the module export list. Test code creates renderers via `newJsonRendererWithHandles`, which is the right pattern, but the constructor leak allows bypassing initialization.
**Fix**: Remove `JsonRenderer(..)` from the export list and export the type name only.

### 1.20: `InteractiveRenderer(..)` constructor exported enables test bypass (Severity: Minor)
**File**: src/Iidy/Output/Renderers/Interactive.hs:6
**What**: `InteractiveRenderer(..)` is exported with all fields, which `Test.Shared` uses to construct renderers directly (lines 91-122) bypassing `newInteractiveRendererWithHandles`. This is intentional for testing but means the renderer can be constructed in an inconsistent state.
**Fix**: Consider exporting field accessors selectively or using a test-only module. This is a pragmatic trade-off for testability.

## Test Coverage Assessment

**Well covered**:
- JSON value conversions: all 26 `OutputData` types have dedicated `*ToValue` conversion tests
- Formatting helpers: `formatSectionHeading`, `formatSectionEntry`, `formatLogicalId`, `padRight`, `calcPadding`, `prettyFormatTags`, `prettyFormatParameters` all have unit tests
- Color system: ANSI code presence/absence tests for colored and plain themes
- Integration: all `OutputData` variants pass through both renderers without crashing
- Output sequences: correct ordering for major operation flows (create, describe, delete, changeset, drift)
- Error formatting colors: dedicated tests for ANSI escape sequences in error output

**Gaps**:
1. **No rendered output content tests**: Integration tests only verify "does not crash" via `try`. No test captures the actual text written to a handle and asserts on its content. This means formatting regressions (wrong column alignment, missing fields, wrong colors for specific statuses) cannot be caught.
2. **No tests for `renderStackDrift`**: The drift rendering logic (property differences, padding, drift status) has no unit tests beyond the integration "doesn't crash" test.
3. **No tests for `renderChangesetChange`**: The changeset change rendering (Add/Remove/Modify/Replace branches, scope display, detail lines) has no targeted tests.
4. **No tests for `renderStackList`**: The stack list rendering (lifecycle icons, environment detection, tag display, failure reason display) has no unit tests.
5. **No tests for `renderConfirmationPrompt`**: The TTY vs non-TTY branching and formatting.
6. **No tests for `wrapText`**: The word-wrapping utility function has no dedicated tests.
7. **No tests for `detectEnvironment`**: The environment detection from stack names and tags.
8. **No tests for `prettyFormatTags` edge cases**: Truncation with `maxTags = Just 0`, `maxTags = Just 1` with an env tag, tags where the key matches an env key variant like "ENV".
9. **No spinner concurrency tests**: Thread management, start/stop cycling, timing display updates.
10. **No tests for `OutputDispatch`**: The `mkOutputDispatch` function and `renderOutput` dispatch are untested.
11. **No tests for `TerminalCapabilities`**: Edge cases like `NO_COLOR` + `FORCE_COLOR` precedence, invalid `COLUMNS` values.
12. **No tests for `Status.hs`**: `categorizeStatus`, `isStatusTerminal`, etc. have no tests at all.

## Positive Observations

1. **Excellent type decomposition in Types.hs**: The `OutputData` sum type with 26 constructors provides exhaustive, type-safe dispatch. Every field is strict (`!`), preventing space leaks. The `deriving stock (Show, Eq)` pattern is consistently applied.

2. **Clean separation of concerns**: The module structure cleanly separates type definitions (Types.hs), color primitives (Color.hs), theme selection (Theme.hs), terminal detection (Terminal.hs), status classification (Status.hs), spinner mechanics (Spinner.hs), and rendering (Interactive.hs, Json.hs). Each small module has a focused responsibility.

3. **Comprehensive test data builders**: `Test.Shared` provides 26 named test builders covering every `OutputData` variant, with `allTestOutputData` ensuring exhaustive coverage and `odConstructorName` enabling sequence assertion. This is well-designed infrastructure.

4. **Correct use of `mask_` for cleanup**: `stopSpinner` and `stopTimingTask` use `mask_` to prevent async exceptions from interrupting the cleanup sequence, which is the right pattern for thread lifecycle management.

5. **No orphan instances**: All types have their instances defined in the same module.

6. **Proper `qualified` imports**: `Data.Map.Strict`, `Data.Text`, `Data.Aeson`, `Data.List.NonEmpty` are all imported qualified, following the project standard.

7. **Safe `maximum` usage**: All `maximum` calls use the `(0 : ...)` pattern to handle empty lists.

8. **Theme system is well-designed**: Four themes (dark, light, high-contrast, no-color) with clear color choices. The `thColorsEnabled` flag properly gates all ANSI output.

9. **Spinner NonEmpty guarantee**: `spinnerFrames` returns `NonEmpty Text`, making it impossible to have a spinner style with zero frames.

10. **JSON renderer properly handles all variants**: Every `OutputData` constructor has a matching handler in `renderOutputDataJson`, and the `OdPollingStarted` no-op is explicitly documented.

## Grade Justification

Starting from 100, deductions:

| Deduction | Issue                                                         | Points |
|:----------|:--------------------------------------------------------------|-------:|
| 1.1       | `encodeValue` ignores pretty-print flag (dead branch)         |     -5 |
| 1.2       | `NE.fromList` partial function in production code             |     -4 |
| 1.3       | Race conditions on shared IORef state across threads          |     -5 |
| 1.6       | Interactive.hs at 1026 LOC (2x over limit)                    |     -3 |
| 1.14      | Inconsistent status classification between Color and Status   |     -2 |
| 1.9       | `prettyFormatTags` truncation edge case                       |     -1 |
| 1.16      | `Nothing` timestamps sort before real timestamps              |     -1 |
| Coverage  | No rendered output content verification tests                 |     -3 |
| Coverage  | No tests for 5+ rendering functions (drift, changeset, list)  |     -2 |

**Total: 74/100**

The system works correctly for the common cases and the architecture is solid. The main concerns are: the `encodeValue` bug silently drops a feature, the IORef concurrency pattern is fragile for multi-threaded access, and the test suite verifies "does not crash" but not "produces correct output". These are fixable without architectural changes.
