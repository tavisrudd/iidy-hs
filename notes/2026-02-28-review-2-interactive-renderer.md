# Code Review: Interactive Renderer Subsystem

**Date:** 2026-02-28
**Reviewer:** Claude Opus 4.6
**Files Reviewed:**

| File                                              | Lines | Role                                      |
|:--------------------------------------------------|------:|:------------------------------------------|
| `src/Iidy/Output/Renderers/Interactive.hs`        |  1048 | Main interactive terminal renderer         |
| `src/Iidy/Output/Types.hs`                        |   457 | OutputData 26-variant sum type definitions |
| `src/Iidy/Output/Color.hs`                        |   236 | Color/theme management                     |
| `src/Iidy/Output/Spinner.hs`                      |   117 | Spinner animation with concurrent threads  |
| `src/Iidy/Output/Manager.hs`                      |   127 | Output dispatch (Interactive/JSON)         |
| `src/Iidy/Output/Terminal.hs`                     |    47 | Terminal capability detection              |
| `src/Iidy/Output/Theme.hs`                        |    39 | Theme resolution                           |
| `src/Iidy/Output/Renderer.hs`                     |    24 | OutputRenderer typeclass                   |
| `test/Test/RendererTest.hs`                        |   225 | Formatting helper unit tests               |
| `test/Test/RendererOutputTest.hs`                  |   146 | Renderer output integration tests          |
| `test/Test/JsonRendererTest.hs`                    |   333 | JSON renderer tests                        |
| `test/Test/IntegrationTest.hs`                     |   239 | Full-pipeline integration tests            |
| `test/Test/ErrorColorTest.hs`                      |   105 | Error color tests                          |
| `test/Test/Shared.hs`                              |   473 | Test data builders + helpers               |

---

## 1. Bugs and Correctness Issues

### 1.1 CRITICAL: `last` on potentially-empty list (Interactive.hs:892)

```haskell
let mLastEventTime = case events of
      [] -> Nothing
      _  -> seTimestamp (sewEvent (last events))
```

This is technically guarded by the `null events` check at line 877, so the `[]` branch here is dead code. However, the **outer** guard means `events` is non-empty when we reach this point, so calling `last events` is safe in practice. But:

- Using `last` on a list is a partial function (violates CLAUDE.md rules: "No partial functions (head, tail, fromJust, etc.)").
- It's O(n) traversal. Should use a safe pattern like `listToMaybe (reverse events)` or better yet, pass the last event explicitly.
- The dead `[] -> Nothing` branch is confusing -- it implies `events` could be empty, but the outer guard already eliminated that possibility.

**Severity: Medium.** Safe at runtime due to guard, but violates project standards and is misleading.

### 1.2 CRITICAL: `!!` in Spinner.hs (lines 57, 73)

```haskell
current = frames !! (frame `mod` length frames)
```

While `mod` guarantees in-range indexing, `!!` is a partial function that would crash on an empty list if `spinnerFrames` ever returned `[]`. Currently all `spinnerFrames` branches return non-empty lists, but there is no type-level guarantee. The `length []` would produce a division-by-zero in `mod` before `!!` even fires, which is actually a worse crash.

**Severity: Medium.** Currently safe because all `spinnerFrames` return non-empty lists, but fragile. Use `Data.List.NonEmpty` or `Vector` to make this statically safe.

### 1.3 `startSpinner` ignores its message parameter (Interactive.hs:181)

```haskell
startSpinner r _msg = do
```

The `_msg` parameter is accepted but discarded. The spinner message is set to `""` on line 190, and the timing loop overwrites it immediately anyway. However, the call site at line 886 passes `"Loading live events..."` -- a caller would reasonably expect this message to appear before the timing loop kicks in on the first 1-second tick.

**Severity: Low.** Cosmetic -- the user sees nothing for the first second after spinner start. The message should be set via `spinnerSetMessage sp _msg` instead of `spinnerSetMessage sp ""`.

### 1.4 `prettyFormatTags` truncation off-by-one edge case (Interactive.hs:435-439)

```haskell
let remaining = mx - length envFormatted
in if remaining < length otherFormatted
   then take (remaining - 1) otherFormatted <> ["..."]
   else otherFormatted
```

If `remaining` is 0 (i.e., `maxTags = Just 1` and there is an env tag), then `remaining - 1 = -1`, so `take (-1)` returns `[]`, and the result is `["..."]`. That gives `maxTags=1` env + `"..."` = 2 items displayed for a max of 1. Edge case but worth noting.

If `remaining` is 1, then `take 0` returns `[]`, so you get `["..."]` instead of showing 1 other tag. The `"..."` replaces the last tag slot, but arguably should only appear if there are *more* tags than the limit.

**Severity: Low.** Edge case unlikely hit in practice.

### 1.5 `detectEnvironment` is case-sensitive for stack names but not tag values (Interactive.hs:1024-1029)

```haskell
detectEnvironment stackName tags
  | T.isInfixOf "production" stackName || Map.lookup "environment" tags == Just "production" = "production"
```

The tag key lookup uses `"environment"` (lowercase) but `prettyFormatTags` searches for `"Environment"`, `"environment"`, `"ENVIRONMENT"`, `"env"`, `"ENV"`. Inconsistency means a stack with tag `Environment=production` (capital E, which is the most common convention) won't get colored, but the tag *will* display first in the formatted output.

**Severity: Medium.** Real-world AWS stacks commonly use `Environment` (capital E). This should use case-insensitive lookup or check multiple key variants like `prettyFormatTags` does.

---

## 2. Non-Idiomatic Haskell

### 2.1 `OutputRenderer` typeclass defined but never used

```haskell
class OutputRenderer r where
  renderInit :: r -> IO r
  renderOutput :: r -> OutputData -> IO r
  renderCleanup :: r -> IO ()
```

This typeclass in `Renderer.hs` is defined but neither `InteractiveRenderer` nor `JsonRenderer` has an instance. The actual dispatch uses the `OutputDispatch` sum type in `Manager.hs`. The typeclass is dead code.

**Severity: Low.** Dead code, should be removed or implemented.

### 2.2 `if-then-else` instead of `when`/`unless` (throughout Interactive.hs)

Many places use `if cond then action else pure ()` where `when` or `unless` would be cleaner:

```haskell
-- Line 348
if hasContent then rPutStrLn r "" else pure ()

-- Line 481
if not (null derived) then do ... else pure ()

-- Line 612
if not (null (scResources contents)) then do ... else pure ()
```

Should be:
```haskell
when hasContent $ rPutStrLn r ""
unless (null derived) $ do ...
unless (null (scResources contents)) $ do ...
```

**Severity: Low.** Style issue, but pervasive (~15 instances).

### 2.3 Manual `orElse` helper instead of `fromMaybe`

```haskell
formatSectionHeading r text =
  let clean = T.stripSuffix ":" text `orElse` text
  in ...
  where
    orElse Nothing  t = t
    orElse (Just v) _ = v
```

This is just `fromMaybe text (T.stripSuffix ":" text)`, which is already imported.

**Severity: Low.** Unnecessary local helper.

### 2.4 `firstJust` re-implements `Data.Foldable.asum` / `Data.Maybe.listToMaybe . mapMaybe`

```haskell
firstJust :: (a -> Maybe b) -> [a] -> Maybe b
firstJust _ []     = Nothing
firstJust f (x:xs) = case f x of
  Just v  -> Just v
  Nothing -> firstJust f xs
```

This is `asum . map f` or `listToMaybe . mapMaybe f`. Not a bug, but reinvents the wheel.

**Severity: Low.**

### 2.5 Record field export from `InteractiveRenderer`

The test module (`Test/Shared.hs`) constructs `InteractiveRenderer` directly by importing its constructor and all fields. This means internal state (IORefs for spinner, timing, etc.) is exposed. The module exports `InteractiveRenderer(..)` which exposes all internals. A smart constructor pattern would be cleaner.

**Severity: Low.** Acceptable for testing, but leaks implementation details.

---

## 3. Code Smells

### 3.1 MAJOR: `renderStackAbsentInfo` and `renderStackAbsentError` are near-identical (lines 928-946)

These two functions differ only in the prefix text (`"info"` with success color vs `"ERROR"` with error color) and the variable name (`info` vs `ctx`). The body (5 `rPutStrLn` calls) is copy-pasted.

```haskell
renderStackAbsentInfo r info = do
  let prefix = colorizeBold (th r) (thSuccess (th r)) "info"
  -- ... identical body ...

renderStackAbsentError r ctx = do
  let prefix = colorizeBold (th r) (thError (th r)) "ERROR"
  -- ... identical body ...
```

Should be factored into a shared helper:

```haskell
renderStackAbsent :: InteractiveRenderer -> Text -> DynColor -> StackAbsentInfo -> IO ()
```

**Severity: Medium.** Violates the "No duplicate code" rule in CLAUDE.md.

### 3.2 MAJOR: `renderChangesetChange` "Modify" branch has copy-pasted code (lines 805-816)

The `Nothing` and `Just "False"` branches of `ciReplacement` are identical:

```haskell
Nothing -> do
  let scopeText = maybe "" (T.intercalate ", ") (ciScope change)
  rPutStrLn r ("  " <> colorize (th r) actionColor (padRight actionW actionText)
    <> " " <> padRight logIdW (ciLogicalResourceId change)
    <> " " <> colorize (th r) (thWarning (th r)) scopeText
    <> " " <> styleMuted r resInfo)
Just "False" -> do
  let scopeText = maybe "" (T.intercalate ", ") (ciScope change)
  rPutStrLn r ("  " <> colorize (th r) actionColor (padRight actionW actionText)
    <> " " <> padRight logIdW (ciLogicalResourceId change)
    <> " " <> colorize (th r) (thWarning (th r)) scopeText
    <> " " <> styleMuted r resInfo)
```

Should combine the patterns: `Nothing -> ...; Just "False" -> ...` into a single case using a guard or `|` pattern.

**Severity: Medium.** Violates the "No duplicate code" rule.

### 3.3 Interactive.hs is too long at 1048 lines

CLAUDE.md says "Try to keep modules under ~300-500 LOC; split if larger and possible." This module is over twice the upper bound. Logical splits:

- `Interactive.hs` -- renderer state, dispatch, spinner management (~200 LOC)
- `Interactive/Format.hs` -- formatting helpers (padRight, calcPadding, prettyFormat*, etc.) (~100 LOC)
- `Interactive/Sections.hs` -- section rendering (metadata, definition, events, contents, etc.) (~600 LOC)
- `Interactive/Changeset.hs` -- changeset rendering (~100 LOC)

**Severity: Medium.** Module is manageable but exceeds project guidelines.

### 3.4 Magic numbers/strings throughout

- `actionW = 8` (line 784)
- `logIdW = 30` (line 785)
- `timePad = 24` (line 724)
- `"\ESC[36;1m"` hardcoded cyan bold (line 193)
- `1000000` microseconds (line 255)
- `"\128274"`, `"\128077"` -- Unicode code points as numeric escapes

These should be named constants or at minimum documented.

**Severity: Low.** Readable in context, but fragile.

### 3.5 `renderCommandMetadata` labels have trailing colons but formatSectionEntry adds none

Labels like `"iidy Environment:"`, `"Region:"`, `"Profile:"` already end in `:` but `formatSectionEntry` just prints them as-is. Meanwhile, `formatSectionHeading` actively *strips* trailing colons before re-adding one. This inconsistency is confusing.

Looking more carefully: `formatSectionEntry` treats its `label` parameter as the raw label text and pads it. The caller passes `"Region:"` and the colon becomes part of the padded label. This works but the convention is inconsistent with `formatSectionHeading` which normalizes colons.

**Severity: Low.** Works correctly but API is inconsistent.

---

## 4. Testing Gaps

### 4.1 No tests for spinner concurrency behavior

The `Spinner.hs` module has no dedicated tests. The concurrent behavior (`forkIO`, `killThread`, `threadDelay`, IORef race conditions) is completely untested. The integration tests use `/dev/null` output and plain options (spinners disabled), so spinner code paths are never exercised in tests.

**What's missing:**
- `spinnerTick` frame advancement
- `spinnerClear` state reset
- `spinnerFinishAndClear` when active vs inactive
- `spinnerIntervalMs` values
- `spinnerFrames` non-emptiness property test
- Concurrent start/stop race conditions

**Severity: High.** The most concurrency-heavy code in the subsystem is untested.

### 4.2 No tests for `renderOutputData` dispatch with colored renderer + real output capture

All integration tests use either `/dev/null` (no output verification) or pure formatting helpers (no IO). There are no tests that:

- Capture actual rendered output to a buffer/handle and verify content
- Test that colors are correctly applied in full render pass
- Verify section ordering/spacing with `irHasRenderedContent` state

**Severity: Medium.** The integration tests verify "doesn't crash" but not "produces correct output."

### 4.3 No tests for `renderNewStackEvents` timing state preservation

The complex logic at lines 880-894 (save timing state, stop spinner, render, restart spinner, restore state) is untested. This is a critical real-time operation path.

**Severity: Medium.**

### 4.4 No tests for edge cases in `wrapText`

The word-wrapping function at lines 1032-1042 has no tests. Edge cases:
- Empty string
- Single word longer than maxW
- All whitespace
- Multiple consecutive spaces

**Severity: Low.** Simple function, but wrapping bugs would be visible.

### 4.5 No tests for `detectEnvironment`

The environment detection logic (case-sensitive tag lookup, substring matching) has no tests. The bug in 1.5 would be caught by tests.

**Severity: Low.**

### 4.6 No property tests for Color.hs

The color module has basic unit tests but no property tests verifying:
- `colorize noColorTheme _ t == t` for all `t`
- `colorize theme color t` always contains `t` as a substring
- SGR codes are valid ANSI sequences
- `colorToSgr` and `colorToBgSgr` produce distinct codes for fg vs bg

**Severity: Low.**

---

## 5. Performance Concerns

### 5.1 Excessive `T.pack (show n)` allocations

Throughout the module, `T.pack (show n)` is used for integer-to-text conversion (lines 235-238, 484, 544, 578, 697, 898, 903). Each call allocates an intermediate `String`. For a renderer that could process hundreds of events, this adds up. Consider using `Data.Text.Builder` or a simple `intToText` helper.

**Severity: Low.** Not a hot path in practice.

### 5.2 `calcPadding` traverses list twice

```haskell
calcPadding items extractor =
  let maxLen = maximum (0 : map (T.length . extractor) items)
  in min maxPadding (max minStatusPadding maxLen)
```

`map` builds an intermediate list, then `maximum` traverses it. Could use `foldl'` for a single pass. However, event lists are small (typically <100 items), so this is negligible.

**Severity: Negligible.**

### 5.3 `sortBy (comparing fst)` on Map.toList

```haskell
otherTags = sortBy (comparing fst) [(k, v) | (k, v) <- Map.toList tags, ...]
```

`Map.toList` already returns keys in sorted order, so the subsequent `sortBy (comparing fst)` is redundant (it only filters out env keys, which wouldn't change the sort order of remaining keys).

**Severity: Low.** Wasted work but on tiny data.

### 5.4 List `++` in `prettyFormatTags`

```haskell
T.intercalate ", " (envFormatted <> truncated)
```

The `<>` on lists is O(n) in the left operand, and `envFormatted` is always 0 or 1 elements, so this is fine. No issue.

---

## 6. Safety Issues

### 6.1 Partial functions already covered

- `last` at line 892 (guarded but violates standard)
- `!!` in Spinner.hs lines 57, 73 (guarded by `mod` but fragile)

### 6.2 `elem` used on list instead of Set

```haskell
not (k `elem` envKeys)
```

Line 431: `elem` on a 5-element list is fine, but GHC may warn about `Foldable` ambiguity depending on settings. Using `notElem` would be slightly cleaner.

**Severity: Negligible.**

### 6.3 No validation of RGB color values

```haskell
Rgb !Int !Int !Int
```

DynColor's `Rgb` constructor accepts arbitrary `Int` values. There is no validation that they are in the 0-255 range. Invalid values would produce malformed ANSI escape sequences that terminals would silently ignore or display incorrectly.

**Severity: Low.** All RGB values are hardcoded in theme definitions, so this only matters if the API is used externally.

### 6.4 Unicode numeric escapes may be misinterpreted

```haskell
<> " \128274"   -- 🔒
<> " \128077"   -- 👍
```

These use Haskell's numeric character escape syntax. While correct, they're hard to verify by inspection. Using the actual Unicode character in the source file (with a comment) would be clearer and less error-prone.

**Severity: Low.** Correct but brittle.

---

## 7. Concurrency Issues

### 7.1 CRITICAL: No exception safety around thread cleanup

`stopSpinner` and `stopTimingTask` use `killThread` but there is no `bracket` or exception handler to ensure cleanup happens if an exception occurs between `startSpinner` and `stopSpinner`. If `renderOutputData` throws, threads are leaked:

```haskell
-- startSpinner creates threads:
tid <- forkIO $ spinnerTickLoop sp colorCode interval
writeIORef (irSpinnerThread r) (Just tid)
-- ...
tid <- forkIO $ timingLoop r sp
writeIORef (irTimingThread r) (Just tid)
```

If any operation between `startSpinner` and `stopSpinner` throws an exception, the background threads continue running indefinitely, writing to the terminal handle.

**Fix:** Use `bracket` pattern:
```haskell
withSpinner :: InteractiveRenderer -> Text -> IO a -> IO a
withSpinner r msg action = bracket (startSpinner r msg) (\_ -> stopSpinner r) (\_ -> action)
```

**Severity: High.** Thread leak in error scenarios.

### 7.2 IORef race conditions between spinner thread and main thread

Multiple IORefs are read and written from both the main thread and background threads without any synchronization:

- `irTimingState` is written by `startTimingTask`/`timingLoop`/`renderNewStackEvents` (both main and background threads)
- `irSpinner` is read by `timingLoop` (background) and written by `startSpinner`/`stopSpinner` (main)
- `spMessage` in Spinner is written by `timingLoop` (background) and read by `spinnerRender` (another background thread)

`IORef` does not guarantee atomicity for compound read-modify-write operations. While individual `readIORef`/`writeIORef` are atomic for boxed values on GHC, the sequence:

```haskell
mState <- readIORef (irTimingState r)
case mState of
  Just (startTime, _) ->
    writeIORef (irTimingState r) (Just (startTime, Just eventTime))
```

...is a read-then-write that could race with `stopTimingTask` setting it to `Nothing`.

**Severity: Medium.** Unlikely to cause crashes (GHC IORef is atomic for single reads/writes of boxed values) but could cause stale data display. The timing display might show wrong elapsed time momentarily. In practice, this is acceptable for a UI spinner.

### 7.3 `killThread` is asynchronous exception delivery

`killThread` throws `ThreadKilled` to the target thread. If the target thread is in the middle of `spinnerRender` (which does `hPutStr` + `hFlush`), it could leave the handle in an inconsistent state (partial ANSI escape written). GHC's Handle implementation is exception-safe for most operations, but partial writes could leave terminal in a bad state.

**Severity: Low.** GHC handles this reasonably well in practice. Terminal ANSI states are recoverable.

### 7.4 `spinnerTickLoop` is an infinite recursion with no exit condition

```haskell
spinnerTickLoop sp colorCode interval = do
  spinnerRender sp colorCode
  threadDelay interval
  spinnerTickLoop sp colorCode interval
```

This loop only terminates via `killThread`. It has no way to check a shutdown flag. This is acceptable for this use case (spinner is meant to run until killed), but it means GHC cannot collect the Spinner value while the loop runs -- it's pinned by the thread closure.

**Severity: Low.** Standard pattern for background animation threads.

### 7.5 No `mask` around stopSpinner thread management

```haskell
stopSpinner r = do
  stopTimingTask r
  mTid <- readIORef (irSpinnerThread r)
  case mTid of
    Just tid -> killThread tid
    Nothing  -> pure ()
  writeIORef (irSpinnerThread r) Nothing
  mSp <- readIORef (irSpinner r)
  case mSp of
    Just sp -> spinnerFinishAndClear sp
    Nothing -> pure ()
  writeIORef (irSpinner r) Nothing
```

If an async exception arrives between `killThread tid` and `writeIORef (irSpinnerThread r) Nothing`, the ref still contains the now-dead ThreadId. A subsequent `stopSpinner` would try to `killThread` it again (benign -- killing a dead thread is a no-op) but the cleanup state is inconsistent.

**Severity: Low.** Would not cause observable bugs due to `killThread` idempotency.

---

## 8. Additional Observations

### 8.1 `DynamicOutputManager` appears unused

The `DynamicOutputManager` type and `newOutputManager` are defined in `Manager.hs` but the actual dispatch mechanism used in production is `OutputDispatch` + `mkOutputDispatch`. The `DynamicOutputManager` with its `domBufferRef :: IORef [OutputData]` seems to be a vestigial design that was superseded.

**Severity: Low.** Dead code.

### 8.2 Color.hs is well-structured

The color module is clean, well-organized, and the theme system is well-designed. Four themes (dark, light, high-contrast, no-color) with consistent fields. The `colorize`/`colorizeBold`/`colorizeOnBg` API is good. The semantic helpers (`colorizeResourceStatus`, `colorByEnvironment`) are appropriately placed.

### 8.3 Types.hs is well-designed

The 26-variant OutputData sum type with strict fields throughout is good. All record types use bang patterns. The type design cleanly separates concerns. Having `Show` and `Eq` instances on everything enables easy testing.

### 8.4 Test data builders are excellent

`Test/Shared.hs` provides a comprehensive set of test data builders for all 26 OutputData types plus the `allTestOutputData` list that covers every variant. The `odConstructorName` function enables sequence testing. This is a well-designed test infrastructure.

### 8.5 `hIsTerminalDevice` called repeatedly in hot path

`startSpinner` (line 183) and `renderConfirmationPrompt` (line 908) call `hIsTerminalDevice` at runtime. This should be cached in the renderer state during initialization, since the TTY status of a handle doesn't change during program execution.

**Severity: Low.** syscall is cheap but unnecessary.

---

## Summary Table

| Category                     | Critical | High | Medium | Low | Negligible |
|:-----------------------------|:--------:|:----:|:------:|:---:|:----------:|
| Bugs/Correctness             |    0     |  0   |   2    |  2  |     0      |
| Non-idiomatic Haskell        |    0     |  0   |   0    |  5  |     0      |
| Code smells                  |    0     |  0   |   3    |  2  |     0      |
| Testing gaps                 |    0     |  1   |   2    |  3  |     0      |
| Performance                  |    0     |  0   |   0    |  2  |     2      |
| Safety                       |    0     |  0   |   0    |  3  |     1      |
| Concurrency                  |    0     |  1   |   1    |  3  |     0      |
| **Total**                    |  **0**   |**2** | **8**  |**20**|   **3**   |

---

## Overall Code Quality Grade: **74 / 100**

### Justification

**Strengths (pushing grade up):**
- Types.hs is excellent: strict fields, clean separation, comprehensive export list
- Color.hs is well-designed with proper theme abstraction
- Test infrastructure (Shared.hs) is thorough with builders for all 26 types
- Integration tests verify all variants don't crash
- Output dispatch pattern is clean and extensible
- The rendering logic correctly handles a complex, multi-section output format
- Proper use of qualified imports, Text over String, no orphan instances

**Weaknesses (pulling grade down):**
- Two high-severity issues: no exception safety around thread lifecycle, no spinner tests
- Two partial function uses (`last`, `!!`) violate stated project standards
- Two significant code duplications (absent info/error, changeset modify branches)
- Module exceeds 2x the stated LOC guideline
- Interactive renderer integration tests verify "no crash" but not "correct output"
- Spinner concurrency code is the most complex part of the subsystem yet has zero tests
- Dead code (OutputRenderer typeclass, DynamicOutputManager)
- Environment detection has case-sensitivity inconsistency with tag formatting

The code is functional and handles the breadth of the 26-variant output type well. The main concerns are around concurrency safety and the testing gap for the concurrent spinner/timing code. For a CloudFormation deployment tool where the spinner is a UI convenience rather than a correctness-critical feature, the concurrency issues are acceptable in practice but represent technical debt that should be addressed.
