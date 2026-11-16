# Interactive Renderer Review Fixes

**Source:** `notes/reviews/2026-02-28-review--interactive-renderer--round-1.md`
**Date:** 2026-03-01

## Fix Plan

13 actionable fixes from the review, grouped into 4 work batches for sub-agent delegation.

---

### Batch 1: Partial Functions & Safety (3 fixes)

| # | Review | File                       | Fix                                                                                     |
|:-:|:------:|:---------------------------|:----------------------------------------------------------------------------------------|
| 1 | 1.1    | Interactive.hs:892         | Replace `last events` with safe pattern using `NonEmpty` or explicit last-element pass   |
| 2 | 1.2    | Spinner.hs:57,73           | Replace `!!` with `NonEmpty` frames or `Vector` indexing                                 |
| 3 | 6.3    | Color.hs (Rgb constructor) | Add smart constructor or `mkRgb` that clamps 0-255 (low priority — all values hardcoded) |

**Fix 1 detail:** Remove the dead `[] -> Nothing` branch. Since the outer guard ensures non-empty, use:
```haskell
let mLastEventTime = seTimestamp (sewEvent (NE.last (NE.fromList events)))
```
Or simpler — just bind the last element before the mapM_:
```haskell
let lastEvent = sewEvent (Prelude.last events)  -- guarded non-empty
    mLastEventTime = seTimestamp lastEvent
```
Best approach: use `Data.List.NonEmpty.last` after `NE.fromList` (safe because guarded), or restructure to pass last event out of `mapM_`.

**Fix 2 detail:** Change `spinnerFrames` return type to `NonEmpty Text`, then use `NE.!!` or convert to `Vector` for O(1) indexing. The `mod` by `length` pattern stays but with `NE.length` which is always >= 1.

**Fix 3 detail:** Skip — all RGB values are hardcoded in theme defs. Note as "won't fix" in this round.

---

### Batch 2: Code Deduplication (3 fixes)

| # | Review | File                           | Fix                                                               |
|:-:|:------:|:-------------------------------|:------------------------------------------------------------------|
| 4 | 3.1    | Interactive.hs:928-946         | Factor `renderStackAbsentInfo`/`Error` into shared helper          |
| 5 | 3.2    | Interactive.hs:805-816         | Merge `Nothing`/`Just "False"` branches in `renderChangesetChange` |
| 6 | 1.5    | Interactive.hs:1024-1029       | Fix `detectEnvironment` to check multiple tag key variants         |

**Fix 4 detail:** Extract:
```haskell
renderStackAbsent :: InteractiveRenderer -> Text -> DynColor -> StackAbsentInfo -> IO ()
renderStackAbsent r label labelColor info = do
  let prefix = colorizeBold (th r) labelColor label
      sn = colorizeBold (th r) (thInfo (th r)) (saiStackName info)
  rPutStrLn r (prefix <> " The stack " <> sn <> " is absent")
  rPutStrLn r ("      env = " <> colorize (th r) (thPrimary (th r)) (saiEnvironment info))
  rPutStrLn r ("      region = " <> colorize (th r) (thPrimary (th r)) (saiRegion info))
  rPutStrLn r ("      account = " <> colorize (th r) (thPrimary (th r)) (saiAccount info))
  rPutStrLn r ("      auth_arn = " <> colorize (th r) (thPrimary (th r)) (saiAuthArn info) <> ".")
```
Then:
```haskell
renderStackAbsentInfo  r = renderStackAbsent r "info"  (thSuccess (th r))
renderStackAbsentError r = renderStackAbsent r "ERROR" (thError (th r))
```

**Fix 5 detail:** Combine patterns:
```haskell
case ciReplacement change of
  Just "True"        -> rPutStrLn r (... resInfo)
  Just "Conditional" -> rPutStrLn r (... resInfo)
  _                  -> do  -- Nothing, Just "False", any other
    let scopeText = maybe "" (T.intercalate ", ") (ciScope change)
    rPutStrLn r (... scopeText ... resInfo)
```
Wait — the `_` wildcard in the outer `case` (lines 798-803) already handles True/Conditional for the action text. The inner `case` on `ciReplacement` dispatches rendering. The `Just "True"` and `Just "Conditional"` inner branches (line 817 `_ ->`) render without scope. So the fix is:
```haskell
case ciReplacement change of
  Just "True"        -> renderWithoutScope
  Just "Conditional" -> renderWithoutScope
  _                  -> renderWithScope  -- Nothing, "False", anything else
```

**Fix 6 detail:** Add case-insensitive tag lookup:
```haskell
lookupEnvTag :: Map Text Text -> Maybe Text
lookupEnvTag tags = firstJust (`Map.lookup` tags)
  ["Environment", "environment", "ENVIRONMENT", "env", "ENV"]

detectEnvironment stackName tags =
  let envVal = T.toLower <$> lookupEnvTag tags
  in ...
```

---

### Batch 3: Dead Code & Idiom Cleanup (5 fixes)

| # | Review | File                   | Fix                                                          |
|:-:|:------:|:-----------------------|:-------------------------------------------------------------|
| 7 | 2.1    | Renderer.hs            | Remove dead `OutputRenderer` typeclass (keep `OutputMode`)    |
| 8 | 8.1    | Manager.hs             | Remove dead `DynamicOutputManager` type + `newOutputManager`  |
| 9 | 2.2    | Interactive.hs         | Replace ~15 `if cond then action else pure ()` with `when`    |
| 10| 2.3    | Interactive.hs         | Replace `orElse` helper with `fromMaybe`                      |
| 11| 2.4    | Interactive.hs         | Replace `firstJust` with `asum . map f` (if `firstJust` unused elsewhere after fix 6) |

**Fix 7 detail:** `Renderer.hs` exports `OutputRenderer(..)` and `OutputMode(..)`. Remove the typeclass, keep `OutputMode`. Check all imports of `OutputRenderer` — should be none since it's unused.

**Fix 8 detail:** Remove `DynamicOutputManager`, `newOutputManager`, and the `domBufferRef` IORef import if unused after removal.

**Fix 9 detail:** Mechanical replacement. `if x then y else pure ()` → `when x y`. `if not x then y else pure ()` → `unless x y`.

**Fix 10 detail:** Replace `orElse` with `fromMaybe`.

**Fix 11 detail:** Keep `firstJust` if it's used by `lookupEnvTag` in fix 6 (which reuses the same pattern). Otherwise replace with `asum . map f`.

---

### Batch 4: Concurrency Safety (2 fixes)

| # | Review | File                   | Fix                                                         |
|:-:|:------:|:-----------------------|:------------------------------------------------------------|
| 12| 7.1    | Interactive.hs         | Add `bracket` pattern for spinner lifecycle                  |
| 13| 1.3    | Interactive.hs:181     | Use `_msg` parameter in `startSpinner`                       |

**Fix 12 detail:** This is the highest-impact fix. Add exception safety:
```haskell
-- In renderNewStackEvents, wrap the body:
withSpinner :: InteractiveRenderer -> Text -> IO a -> IO a
withSpinner r msg action = bracket_ (startSpinner r msg) (stopSpinner r) action
```
However, the current usage pattern is more complex — `startSpinner` and `stopSpinner` are called at different points in the flow, not in a nested bracket. The spinner starts in `OdPollingStarted` and stops in various places. A full `bracket` refactor would require restructuring the output dispatch flow.

**Pragmatic fix:** Add exception handler in `stopSpinner` to mask async exceptions during cleanup, and add a finalizer in `renderOutputData` for the polling case:
```haskell
stopSpinner r = mask_ $ do
  stopTimingTask r
  mTid <- readIORef (irSpinnerThread r)
  ...
```

**Fix 13 detail:** In `startSpinner`, change `spinnerSetMessage sp ""` to `spinnerSetMessage sp _msg` (rename `_msg` to `msg`).

---

### Deferred (not fixing this round)

| Review | Reason                                                              |
|:------:|:--------------------------------------------------------------------|
| 3.3    | Module split — too large a refactor for a fix round                  |
| 3.4    | Magic numbers — cosmetic, low value                                  |
| 3.5    | Label colon inconsistency — cosmetic                                 |
| 4.1-4.6| Test gaps — separate work item, not a code fix                      |
| 5.1-5.4| Performance — negligible impact                                     |
| 6.2    | `elem` on 5-element list — negligible                                |
| 6.4    | Unicode escapes — cosmetic                                           |
| 7.2-7.5| Concurrency edge cases — acceptable for spinner UI                  |
| 8.5    | Cache `hIsTerminalDevice` — minor optimization                       |
| 6.3    | RGB validation — all values hardcoded                                |

---

## Execution Status

| Batch | Description              | Status   | Files Changed                                  |
|:-----:|:-------------------------|:---------|:-----------------------------------------------|
|   1   | Partial functions/safety | DONE     | Interactive.hs, Spinner.hs                      |
|   2   | Code deduplication       | DONE     | Interactive.hs                                  |
|   3   | Dead code & idioms       | DONE     | Interactive.hs, Renderer.hs, Manager.hs, Spinner.hs |
|   4   | Concurrency safety       | DONE     | Interactive.hs                                  |

## Verification

- Build: PASS (zero warnings, -Wall -Wcompat)
- Tests: 851/851 passing
- Render snapshots: 35/37 pass (2 pre-existing failures)
- Error snapshots: 48/49 pass (1 pre-existing failure)
