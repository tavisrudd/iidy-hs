# Fix Noisy Integration Tests -- Implementation Plan

**Status**: DONE
**Date**: 2026-02-25
**Session**: `8334c9cc-a311-4d42-937f-314d40b539f5`
**References**: `notes/2026-02-24-noisy-tests.md` (corrected), `notes/2026-02-24-silent-tests.md` (failed hCapture approach)

## Context

12 integration tests in `Test.IntegrationTest` produce ~528 lines of noise
per test run. They call `renderOutputData` / `renderOutputDataJson` which
write directly to hardcoded `stdout`/`stderr` via `TIO.putStrLn` etc.

A previous attempt (Codex, Feb 24) tried wrapping tests with
`hCapture [stdout, stderr]` from the `silently` package. This failed because
it also captured Tasty's own runner output, making the suite appear truncated.

The correct fix: make the renderers write to configurable `Handle`s instead of
hardcoded `stdout`/`stderr`. Tests pass in `/dev/null` handles; production
passes in real `stdout`/`stderr`.

## Key Architecture Decision

**Chosen**: Add `Handle` fields to renderer types (stdout + stderr handles).

**Why**: Minimal change, no new dependencies, testable. The `Handle` abstraction
already exists in the codebase (`System.IO`). Production code creates renderers
with real handles; tests create renderers with `/dev/null` handles.

**Rejected alternatives**:
- `hCapture` from `silently` — captures Tasty output too (proven failure)
- Writer monad / `Text` accumulation — large refactor, breaks streaming output
- Tasty `--quiet` flag — hides test names too, defeats purpose

## Chunks

### Chunk 1: Add Handle fields to InteractiveRenderer

Add `irStdout :: !Handle` and `irStderr :: !Handle` to `InteractiveRenderer`.
Update `InteractiveOptions` or `newInteractiveRenderer` to accept handles
(default to `stdout`/`stderr`).

Replace all ~88 bare `TIO.putStrLn` / `TIO.putStr` / `putStr` / `hFlush stdout`
calls in Interactive.hs with handle-parameterized equivalents:
- `TIO.putStrLn x` → `TIO.hPutStrLn (irStdout r) x`
- `TIO.putStr x` → `TIO.hPutStr (irStdout r) x`
- `hFlush stdout` → `hFlush (irStdout r)`
- The ~2 `TIO.hPutStrLn stderr` calls stay as `TIO.hPutStrLn (irStderr r)`

Also update `Spinner` module — `spinnerRender` and `spinnerFinishAndClear`
write to `stdout`. Add a `Handle` field to `Spinner` or pass it through.

**Files**: `src/Iidy/Output/Renderers/Interactive.hs`, `src/Iidy/Output/Spinner.hs`

Code sketch:
```haskell
data InteractiveRenderer = InteractiveRenderer
  { irStdout             :: !Handle
  , irStderr             :: !Handle
  , irTheme              :: !IidyTheme
  , irOptions            :: !InteractiveOptions
  -- ... rest unchanged
  }

newInteractiveRenderer :: Handle -> Handle -> InteractiveOptions -> IO InteractiveRenderer
newInteractiveRenderer hOut hErr opts = do
  -- Terminal detection should check hOut, not hardcoded stdout
  caps <- detectCapabilitiesFor hOut
  ...

-- Or: keep newInteractiveRenderer unchanged, add newInteractiveRendererWithHandles
-- and have the default use stdout/stderr
```

### Chunk 2: Add Handle fields to JsonRenderer

Add `jrStdout :: !Handle` and `jrStderr :: !Handle` to `JsonRenderer`.

Replace the ~5 bare stdout writes in Json.hs:
- `outputLine` / `outputRawJson`: `TIO.putStrLn` → `TIO.hPutStrLn (jrStdout r)`
- `hFlush stdout` → `hFlush (jrStdout r)`
- `OdStackTemplate` stderr path: already uses `stderr`, change to `jrStderr r`

**Files**: `src/Iidy/Output/Renderers/Json.hs`

Code sketch:
```haskell
data JsonRenderer = JsonRenderer
  { jrOptions :: !JsonOptions
  , jrStdout  :: !Handle
  , jrStderr  :: !Handle
  }

newJsonRenderer :: JsonOptions -> JsonRenderer
newJsonRenderer opts = JsonRenderer opts stdout stderr

newJsonRendererWithHandles :: Handle -> Handle -> JsonOptions -> JsonRenderer
newJsonRendererWithHandles = JsonRenderer . flip const  -- or just direct construction
```

### Chunk 3: Update OutputDispatch / Manager

Update `mkOutputDispatch` and `renderOutput` to thread handles through.
Production callers pass `stdout`/`stderr`.

**Files**: `src/Iidy/Output/Manager.hs`

### Chunk 4: Update integration tests to use /dev/null handles

Create a test helper that opens `/dev/null` for writing and passes those
handles to the renderer constructors.

```haskell
withSilentRenderer :: (InteractiveRenderer -> IO a) -> IO a
withSilentRenderer action =
  withFile "/dev/null" WriteMode $ \devNull ->
    newInteractiveRenderer devNull devNull plainInteractiveOptions >>= action
```

Apply to all 12 noisy tests. Verify the tests still pass (they test
"doesn't crash", not output content).

**Files**: `test/Test/IntegrationTest.hs`, possibly `test/Test/Shared.hs`

### Chunk 5: Verify & clean up

- Run full test suite, confirm zero noise
- Delete `notes/2026-02-24-silent-tests.md` (superseded)
- Update `notes/2026-02-24-noisy-tests.md` to note resolution

## Codebase Reference

| What                                         | Where                                                    |
|----------------------------------------------|----------------------------------------------------------|
| InteractiveRenderer type                      | `src/Iidy/Output/Renderers/Interactive.hs:115-126`       |
| newInteractiveRenderer                        | `src/Iidy/Output/Renderers/Interactive.hs:128-148`       |
| printSectionHeading (sample stdout write)     | `src/Iidy/Output/Renderers/Interactive.hs:321-327`       |
| renderStackTemplate (stderr write)            | `src/Iidy/Output/Renderers/Interactive.hs:928-931`       |
| renderConfirmationPrompt (TTY check on stdout)| `src/Iidy/Output/Renderers/Interactive.hs:882-892`       |
| JsonRenderer type                             | `src/Iidy/Output/Renderers/Json.hs:76-78`               |
| outputLine (stdout write)                     | `src/Iidy/Output/Renderers/Json.hs:152-155`             |
| Spinner module                                | `src/Iidy/Output/Spinner.hs`                             |
| OutputDispatch                                | `src/Iidy/Output/Manager.hs:80-87`                       |
| mkOutputDispatch                              | `src/Iidy/Output/Manager.hs:91-126`                      |
| Integration tests                             | `test/Test/IntegrationTest.hs`                           |
| detectCapabilities                            | `src/Iidy/Output/Terminal.hs`                            |

## Build/Test Commands

Per CLAUDE.md — use `~/.claude/bin/run-quiet` for builds.

## Delegation Strategy

| Chunk                    | Delegate? | Agent  | Notes                                                    |
|--------------------------|-----------|--------|----------------------------------------------------------|
| 1 (Interactive Handle)   | Yes       | Sonnet | Mechanical replacement (~88 call sites), clear pattern   |
| 2 (Json Handle)          | Yes       | Sonnet | Small file, ~5 replacements                              |
| 3 (Manager update)       | Yes       | Sonnet | Small, follows pattern from 1-2                          |
| 4 (Test update)          | Yes       | Sonnet | Straightforward test helper                              |
| 5 (Verify)               | No        | Main   | Integration check, human review                          |

Chunks 1-3 can be done in one commit. Chunk 4 in a second. Chunk 5 is verification.

## Workflow Instructions

- Read this file first
- Check Progress to see what's next
- After completing work, update Progress and add Handoff Notes
- Record session ID in each Handoff Notes entry
- Note: Interactive.hs has ~88 stdout write sites — use search-and-replace, not manual edits

## Progress

- [x] Chunk 1: Add Handle fields to InteractiveRenderer + Spinner
- [x] Chunk 2: Add Handle fields to JsonRenderer
- [x] Chunk 3: Update OutputDispatch / Manager to thread handles (no changes needed — defaults handle it)
- [x] Chunk 4: Update integration tests to use /dev/null handles
- [x] Chunk 5: Verify clean output — 405 tests pass, zero noise

## Handoff Notes

### 2026-02-25 — All chunks complete
- Spinner: Added `spHandle :: !Handle` field, `newSpinner` now takes Handle param
- InteractiveRenderer: Added `irStdout`/`irStderr` fields, `newInteractiveRendererWithHandles` constructor, internal helpers `rPutStrLn`/`rPutStr`/`rFlush`/`rPutStrLnErr`, all ~88 bare stdout/stderr writes replaced
- JsonRenderer: Added `jrStdout`/`jrStderr` fields, `newJsonRendererWithHandles` constructor, all 5 bare writes replaced
- Manager: No changes needed — `newInteractiveRenderer`/`newJsonRenderer` default to stdout/stderr
- Tests: `withSilentInteractiveRenderer`/`withSilentJsonRenderer` helpers using `/dev/null`, all 12 integration tests silent
- Test.Shared: `mkColoredRenderer`/`mkPlainRenderer` updated with handle fields (use real stdout/stderr for unit test formatters)
- 405 tests pass, zero warnings, zero render noise in test output
