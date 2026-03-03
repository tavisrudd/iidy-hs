# Code Review Round 3: Interactive Renderer Subsystem

**Date**: 2026-03-01
**Round**: 3 of 3
**Reviewer**: Claude Opus 4.6 (independent)
**Scope**: Interactive renderer, JSON renderer, output types, color/theme/spinner infrastructure, and associated tests

| #  | File                                               | LOC  |
|----|----------------------------------------------------|------|
| 1  | src/Iidy/Output/Renderers/Interactive.hs           | 1020 |
| 2  | src/Iidy/Output/Types.hs                           |  456 |
| 3  | src/Iidy/Output/Color.hs                           |  237 |
| 4  | src/Iidy/Output/Spinner.hs                         |  117 |
| 5  | src/Iidy/Output/Manager.hs                         |   71 |
| 6  | src/Iidy/Output/Terminal.hs                        |   46 |
| 7  | src/Iidy/Output/Theme.hs                           |   38 |
| 8  | src/Iidy/Output/Renderer.hs                        |   10 |
| 9  | src/Iidy/Output/Status.hs                          |   45 |
| 10 | src/Iidy/Output/Renderers/Json.hs                  |  521 |
| 11 | test/Test/RendererTest.hs                           |  224 |
| 12 | test/Test/RendererOutputTest.hs                     |  145 |
| 13 | test/Test/JsonRendererTest.hs                       |  332 |
| 14 | test/Test/IntegrationTest.hs                        |  238 |
| 15 | test/Test/ErrorColorTest.hs                         |  104 |
| 16 | test/Test/Shared.hs                                 |  472 |
|    | **Total**                                          | 4076 |

## Grade: 78/100

## Summary

The interactive renderer subsystem is a well-structured output pipeline with clean separation between rendering modes (interactive/JSON/plain), theme management, and terminal capability detection. The architecture -- a discriminated union of `OutputData` variants dispatched through `OutputDispatch` to either an `InteractiveRenderer` or `JsonRenderer` -- is sound and follows the Rust original's design well.

However, the review identified several issues: the `Interactive.hs` module at 1020 LOC is roughly 2x the project's target ceiling of 300-500 LOC; there are thread safety concerns in the spinner/timing subsystem where `readIORef`/`writeIORef` are mixed with `atomicWriteIORef` on concurrently-accessed IORefs; partial functions (`!!`, `error`) appear in spinner code and test code; the `newInteractiveRendererWithHandles` constructor runs terminal detection even when handles are not connected to a terminal (affecting tests); and multiple rendering functions contain structurally duplicated patterns that could be extracted. Test coverage is solid for value conversion and crash-resistance but lacks output content verification for most rendering paths.

## Issues Found

### 1.1: Spinner uses partial (!!) indexing (Severity: Minor)

**File**: src/Iidy/Output/Spinner.hs:60,76
**What**: `spinnerTick` and `spinnerFrame` use `NE.toList frames !! (frame \`mod\` NE.length frames)`. While the modular arithmetic guarantees the index is in-bounds, the `(!!)` operator is a partial function and is flagged by project coding standards ("No partial functions"). Converting to a NonEmpty list and then back to a regular list to use `(!!)` defeats the purpose of using NonEmpty.
**Fix**: Use a safe indexing approach. Since the frame count is modular, a clean approach is `NE.toList frames` replaced with `cycle (NE.toList frames)` and `take`/`drop`, or simply use `NE.!! ` which is still partial but at least type-restricted, or better yet write a `safeIndex` helper that pattern-matches.

### 1.2: Interactive.hs exceeds module size guideline at 1020 LOC (Severity: Minor)

**File**: src/Iidy/Output/Renderers/Interactive.hs (1020 lines)
**What**: At 1020 LOC this module is roughly 2x the project's 300-500 LOC guideline. The rendering functions for individual `OutputData` variants (lines 455-1003) could be split into a separate internal module.
**Fix**: Extract rendering helpers (e.g., `renderStackDefinition`, `renderStackEvents`, `renderStackContents`, `renderStackList`, `renderStackDrift`, `renderChangesetResult`, `renderChangesetChange`, and utility helpers like `wrapText`, `boolText`, `detectEnvironment`) into `Iidy.Output.Renderers.Interactive.Sections` or similar. Keep the main dispatch, spinner management, and formatting primitives in the current module.

### 1.3: Thread safety: mixed readIORef/writeIORef with atomicWriteIORef on concurrent IORefs (Severity: Major)

**File**: src/Iidy/Output/Renderers/Interactive.hs:261,286,348,351,378,380
**What**: The `irTimingState`, `irSpinner`, and `irHasRenderedContent` IORefs are read with `readIORef` and written with a mix of `writeIORef` (lines 351, 380) and `atomicWriteIORef` (lines 248, 289, etc.). The timing loop (line 261) reads `irTimingState` with `readIORef` from a background thread, while `stopTimingTask` writes it with `atomicWriteIORef` from the main thread. The `readIORef` is not atomic and may see torn writes on some architectures. More critically, `irHasRenderedContent` is only ever accessed from the main thread (since `renderOutputData` is single-threaded), so `writeIORef` is fine there, but `irTimingState` is genuinely shared between threads.
**Fix**: Use `atomicModifyIORef'` for read-modify-write patterns on `irTimingState` (particularly in `updateLastEventTime` at line 286). Consider using an `MVar` or `TVar` for `irTimingState` and `irSpinner`/`irSpinnerThread` since they are shared across threads, which would make the concurrent access pattern explicit.

### 1.4: Spinner tick thread is not killed on exception (Severity: Minor)

**File**: src/Iidy/Output/Renderers/Interactive.hs:199-209
**What**: `startSpinner` forks a thread (`spinnerTickLoop`) but if an exception occurs between `forkIO` and `atomicWriteIORef (irSpinnerThread r) (Just tid)`, the thread reference is lost. Also, `spinnerTickLoop` is an infinite loop that only terminates when `killThread` is called. If `stopSpinner` is never called (e.g., due to an exception in `renderOutputData`), the background thread leaks.
**Fix**: Use `bracket` or ensure `stopSpinner` is called in a `finally` block at the top level of command execution. Alternatively, have the spinner thread check an `IORef Bool` to know when to stop, making `killThread` a backup rather than the primary mechanism.

### 1.5: newInteractiveRendererWithHandles calls detectCapabilities unconditionally (Severity: Minor)

**File**: src/Iidy/Output/Renderers/Interactive.hs:139-160
**What**: `newInteractiveRendererWithHandles` always calls `detectCapabilities` which checks `hIsTerminalDevice stdout` (line 20 of Terminal.hs). But the renderer may be constructed with handles pointing to `/dev/null` (as in tests). The detection checks `stdout` specifically, not the provided handles, so the capabilities may not match the actual output destination. This is partially mitigated by the `InteractiveOptions` overriding some values, but the `tcHasColor` and `tcIsTty` from detection refer to `stdout`, not `hOut`.
**Fix**: Either pass the output handle to `detectCapabilities` so it checks the correct handle, or accept the current behavior and document it clearly. The test code works around this by bypassing the constructor (directly constructing `InteractiveRenderer` values in `mkColoredRenderer`/`mkPlainRenderer`).

### 1.6: startSpinner re-checks hIsTerminalDevice on every call (Severity: Minor)

**File**: src/Iidy/Output/Renderers/Interactive.hs:187
**What**: `startSpinner` calls `hIsTerminalDevice (irStdout r)` every time it is invoked. This is a system call and the result will not change during the lifetime of the renderer. The TTY status should be detected once at construction time and stored.
**Fix**: Add an `irIsTty :: !Bool` field to `InteractiveRenderer`, set it once in the constructor, and use it in `startSpinner` instead of re-calling `hIsTerminalDevice`.

### 1.7: renderNewStackEvents restarts spinner unconditionally (Severity: Minor)

**File**: src/Iidy/Output/Renderers/Interactive.hs:865
**What**: `renderNewStackEvents` always calls `startSpinner r "Loading live events..."` after rendering events, even if the spinner was not running before (e.g., when spinners are disabled or output is not a TTY). While `startSpinner` has its own guard for this, it still calls `stopSpinner` first (line 192), which does `mask_` + thread operations. This is wasted work in non-interactive mode.
**Fix**: Check `ioEnableSpinners` before calling `startSpinner` in `renderNewStackEvents`, or store a flag indicating whether a spinner was active before `stopSpinner` was called.

### 1.8: Duplicated status-reason display logic (Severity: Minor)

**File**: src/Iidy/Output/Renderers/Interactive.hs:497-503 and 738-743
**What**: The logic for deciding when to show a failure reason (checking for `FAILED` suffix, `ROLLBACK_COMPLETE`, `UPDATE_ROLLBACK_COMPLETE`) is duplicated between `renderStackDefinition` (lines 497-503) and `renderStackList` (lines 738-743). The same pattern of `T.isInfixOf "FAILED" status || status == "ROLLBACK_COMPLETE" || status == "UPDATE_ROLLBACK_COMPLETE"` appears in both places.
**Fix**: Extract a predicate like `shouldShowStatusReason :: Text -> Bool` or reuse `isStatusFailed` from `Status.hs` plus explicit checks for rollback statuses.

### 1.9: Partial functions (error) in test code (Severity: Minor)

**File**: test/Test/ErrorColorTest.hs:49,57
**What**: Lines 49 and 57 use `error "expected non-empty output"` and `error "expected 'available variables' line"` inside pattern matches. These are partial functions that will produce unhelpful stack traces if they fire.
**Fix**: Replace with `assertFailure` which is the proper tasty-hunit mechanism for test failures and produces better error messages.

### 1.10: Partial function (V.head) in test code (Severity: Minor)

**File**: test/Test/RendererOutputTest.hs:141
**What**: `V.head arr` is used without checking that the vector is non-empty. While the test asserts `V.length arr == 1` on the previous line, `V.head` is still a partial function. If the assertion library is configured to continue on failure, `V.head` could crash.
**Fix**: Use pattern matching or `V.headM` to safely access the first element.

### 1.11: Spinner NE.toList conversion is wasteful (Severity: Minor)

**File**: src/Iidy/Output/Spinner.hs:60,76
**What**: `NE.toList frames !! (frame \`mod\` NE.length frames)` converts the NonEmpty list to a regular list on every tick (10 times per second for Dots style). While the lists are small (8-13 elements), this is unnecessary allocation on a hot path.
**Fix**: Pre-compute the list in the `Spinner` data structure, or use `Data.Vector` for O(1) indexing, or compute the frame using a cyclic pattern without list conversion.

### 1.12: detectCapabilities only checks stdout (Severity: Minor)

**File**: src/Iidy/Output/Terminal.hs:20
**What**: `detectCapabilities` hardcodes `hIsTerminalDevice stdout`. This means if a renderer writes to stderr or to a file handle, the detection is incorrect.
**Fix**: Parameterize `detectCapabilities` to take a `Handle` argument: `detectCapabilities :: Handle -> IO TerminalCapabilities`.

### 1.13: Color.hs Rgb constructor allows out-of-range values (Severity: Minor)

**File**: src/Iidy/Output/Color.hs:47
**What**: `Rgb !Int !Int !Int` accepts any Int values, including negative numbers or values > 255. While in practice the values are hardcoded in theme definitions, the type does not prevent misuse.
**Fix**: Use `Word8` instead of `Int` for the RGB components, or add a smart constructor that validates the range.

### 1.14: themeFromEnv uses String-level toLower (Severity: Minor)

**File**: src/Iidy/Output/Theme.hs:23
**What**: `fmap (map toLower) env` operates on `String` (`[Char]`) since `lookupEnv` returns `Maybe String`. This is fine functionally but inconsistent with the project standard of preferring `Text`. The `Data.Char.toLower` import is only needed for this one use.
**Fix**: This is acceptable given `lookupEnv` returns `String`, but could be cleaned up by converting to `Text` first and using `T.toLower`.

### 1.15: JSON renderer OdConfirmationPrompt bypasses outputJson wrapper (Severity: Minor)

**File**: src/Iidy/Output/Renderers/Json.hs:113-121
**What**: The `OdConfirmationPrompt` case manually constructs a JSON object with a "type" field and calls `outputLine` directly, bypassing the `outputJson` helper that all other variants use. This means the envelope structure differs from other types (it has "type" at the top level rather than as part of the wrapper).
**Fix**: Use the `outputJson` helper with a dedicated `confirmationToValue` function to maintain consistent envelope structure.

### 1.16: Inconsistent use of atomicWriteIORef vs writeIORef (Severity: Minor)

**File**: src/Iidy/Output/Spinner.hs:62,68-69
**What**: `spinnerTick` uses `writeIORef` to update `spFrameRef` and `spActive`, while these may be read from the main thread during `spinnerFinishAndClear`. Since the spinner tick loop runs in a forked thread, these writes should use `atomicWriteIORef` for memory visibility guarantees.
**Fix**: Use `atomicWriteIORef` for all writes in `spinnerTick` and `spinnerClear`, or document why non-atomic writes are acceptable (e.g., if the IORef is only accessed from one thread at a time).

### 1.17: renderCommandResult uses formatSectionHeading for "SUCCESS" but raw colorize for "FAILURE" (Severity: Minor)

**File**: src/Iidy/Output/Renderers/Interactive.hs:676-678
**What**: The success case uses `formatSectionHeading r "SUCCESS"` (which adds bold + section color + colon) while the failure case uses `colorize (th r) (thError (th r)) "FAILURE" <> ":"`. This asymmetry means SUCCESS gets the section heading color and bold, while FAILURE gets error color without bold. This may be intentional to match Rust behavior, but it is visually inconsistent.
**Fix**: Verify against Rust output. If both should be bold, use `colorizeBold` for the failure case.

### 1.18: prettyFormatTags uses `elem` on a list of keys for every tag (Severity: Minor)

**File**: src/Iidy/Output/Renderers/Interactive.hs:432
**What**: `not (k \`elem\` envKeys)` performs a linear scan of `envKeys` (5 elements) for each tag in the map. While the lists are small, using a `Set` would be more idiomatic.
**Fix**: Use `Data.Set.fromList envKeys` and `Set.member` instead of `elem`. Alternatively, since the list is always 5 elements, this is fine for practical purposes.

## Test Coverage Assessment

**Strengths:**
- All 26 `OutputData` constructors have test data builders (verified by `allTestOutputData` + constructor name check)
- Both renderers are tested for crash-resistance across all variants (integration tests render every variant to `/dev/null`)
- Multiple operation sequences (create-stack, describe-stack, delete-stack, changeset, drift, lint+approval) are tested end-to-end
- JSON value conversion has thorough field-level assertions for all major types
- Color application is tested for both enabled and disabled themes
- Error color output is tested for ANSI escape presence and correct color codes

**Gaps:**
1. **No output content verification for interactive renderer**: Integration tests only verify the renderer does not crash. They do not capture or assert on the actual text output. A test that captures rendered output to a `Handle` backed by an `IORef` or `ByteString` buffer would enable assertions about output content, formatting, alignment, and ANSI codes.
2. **Spinner is untested**: No tests exercise `startSpinner`, `stopSpinner`, `spinnerTick`, `spinnerRender`, or the timing loop. The background thread behavior is completely untested.
3. **Terminal detection is untested**: `detectCapabilities` is never tested with various environment variable combinations (NO_COLOR, FORCE_COLOR, COLORTERM, COLUMNS).
4. **Theme resolution is untested**: `resolveTheme` and `themeFromEnv` have no tests verifying correct theme selection based on inputs.
5. **Edge cases in text formatting**: `wrapText` has no direct tests. `padRight` with very long text containing ANSI codes could produce misaligned output (ANSI escape sequences add to `T.length` but not visual width).
6. **OutputDispatch not tested**: `mkOutputDispatch` is never tested -- the mapping from `GlobalOpts` to renderer type is uncovered.
7. **Stack list rendering paths**: Query mode vs. non-query mode, empty stack lists, stacks with StackSet prefixes, lifecycle icons -- none of these rendering paths are tested for output content.
8. **`renderConfirmationPrompt` TTY vs non-TTY paths**: Both paths exist but neither is tested.

## Positive Observations

1. **Clean architecture**: The `OutputData` sum type as a central dispatch mechanism is well-designed. Adding a new output type requires adding a constructor, a rendering case, and a JSON conversion -- all in predictable locations.

2. **Consistent use of strict fields**: Every data type in `Types.hs` uses bang patterns on all fields, preventing space leaks from lazy accumulation.

3. **Safe `maximum` usage**: All three uses of `maximum` in Interactive.hs prepend `0` to the list (`maximum (0 : map ...)`), preventing the partial function crash on empty lists.

4. **Thorough JSON coverage**: Every `OutputData` variant has a corresponding `*ToValue` function with field-level tests. The JSON envelope structure is tested for both with-type and without-type modes.

5. **Test data builders are well-organized**: `Test.Shared` provides a complete set of realistic test data builders that are reused across all test modules, avoiding duplication.

6. **Theme system is clean**: The separation of `DynColor` (ANSI codes), `IidyTheme` (semantic colors), `ColorTheme` (user selection), and `resolveTheme` (composition) is well-layered.

7. **Defensive rendering**: The main `renderOutputData` dispatch clears spinners before rendering non-spinner content (line 299-303), preventing garbled output.

8. **Proper use of mask_ for thread cleanup**: `stopSpinner` and `stopTimingTask` use `mask_` to prevent async exceptions from interrupting cleanup, which is correct practice.

9. **Color bypass**: The `noColorTheme` / `thColorsEnabled` flag cleanly bypasses all ANSI code generation, making the code testable and CI-friendly.

10. **Status categorization**: `Status.hs` provides a clean, centralized categorization of CloudFormation statuses that is reused in both color application and status queries.

## Grade Justification

| Category                    | Deduction | Notes                                                        |
|-----------------------------|-----------|--------------------------------------------------------------|
| Module size (1020 LOC)      | -3        | 2x guideline ceiling, should be split                        |
| Thread safety (IORef)       | -6        | Mixed atomic/non-atomic on concurrent IORefs                 |
| Spinner thread leak risk    | -3        | No cleanup on exception, infinite loop                       |
| Partial functions (!!)      | -2        | In Spinner.hs, project standard forbids                      |
| Partial functions (error)   | -2        | In test code ErrorColorTest.hs                               |
| detectCapabilities hardcode | -2        | Checks stdout regardless of actual output handle             |
| Test gap: no output capture | -4        | Interactive output content never verified                    |
| Test gap: spinner untested  | -3        | All spinner/timing code is untested                          |
| Test gap: terminal/theme    | -2        | detectCapabilities and resolveTheme untested                 |
| Duplicated logic            | -2        | Status reason display duplicated in 2 places                 |
| JSON ConfirmationPrompt     | -1        | Bypasses outputJson wrapper, inconsistent envelope           |
| **Total deductions**        | **-30**   |                                                              |
| **Positive adjustments**    | **+8**    | Clean architecture, thorough JSON tests, defensive rendering |
| **Final grade**             | **78**    |                                                              |
