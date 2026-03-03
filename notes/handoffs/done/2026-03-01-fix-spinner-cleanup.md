# Fix Spinner Thread Exception Safety (H-5)

**Status**: DONE
**Severity**: High
**File**: `src/Iidy/Output/Renderers/Interactive/Sections.hs` (and related spinner code)

## Problem

The spinner is started as a background thread but there is no `bracket` or `finally`
pattern to ensure `spinnerFinishAndClear` is called if the main operation throws.
If a network error occurs during polling, the spinner animation continues writing to
the terminal, corrupting error output.

## Fix

Wrap spinner usage in `bracket` or `finally`:
```haskell
bracket startSpinner stopSpinner $ \_ -> do
  -- polling operation
```

Or use `finally`:
```haskell
pollingAction `finally` spinnerFinishAndClear spinner
```

Find all call sites where the spinner is started and ensure cleanup on exception.

## Verification
- `cabal build` zero warnings
- `cabal test` all 972+ tests pass
- Manual reasoning: verify all spinner start/stop paths are exception-safe
