# Refactor app/Main.hs — Reduce Logic, Minimal Plumbing Only

**Date**: 2026-03-01
**References**: `app/Main.hs` (499 LOC), Session 41 handoff

## Context

`app/Main.hs` has grown to ~500 LOC and contains substantial business logic
that belongs in library modules: AWS env creation, stack-args merging,
credential detection, output dispatch setup, command metadata emission,
timing provider selection, and the full `runCfnWithArgs` orchestration.

The executable entry point should be minimal plumbing: parse CLI, dispatch
to library functions, handle exit codes. All orchestration logic should
live in `src/Iidy/` where it can be tested and reused.

## Instructions for Next Agent

**Do NOT start implementing immediately.** First:

1. Read `app/Main.hs` in full
2. Identify each block of logic that isn't pure CLI plumbing
3. Research where each block should move (existing modules or new ones)
4. Write a chunked plan in the "Chunks" section below
5. Get user approval before implementing

Key areas likely needing extraction:
- `runCfnWithArgs` (~80 lines of orchestration) → new `Iidy.Cfn.Runner` or similar
- `createAwsEnv` / credential detection → `Iidy.Aws.Config` or `Iidy.Aws.Auth`
- `timeProviderForOperation` → already in Timing, may just need re-export
- `generateToken` → small utility, could stay or move
- Signal handler setup → could be a library helper
- Output dispatch wiring → `Iidy.Output.Manager` already exists, may absorb more

The goal: `app/Main.hs` should be ~100-150 LOC of `main = parseCliOpts >>= dispatch`
style plumbing.

## Codebase Reference

| What                      | Where                                |
|---------------------------|--------------------------------------|
| Main.hs                   | `app/Main.hs` (499 LOC)             |
| Output dispatch           | `src/Iidy/Output/Manager.hs`        |
| Timing providers          | `src/Iidy/Aws/Timing.hs`            |
| CfnContext creation       | `src/Iidy/Cfn/Context.hs`           |
| StackArgs loading         | `src/Iidy/Cfn/StackArgsLoader.hs`   |
| Command metadata          | `src/Iidy/Cfn/CommandMetadata.hs`    |
| CLI types                 | `src/Iidy/Cli.hs`                   |

## Build/Test Commands

Per CLAUDE.md.

## Delegation Strategy

- **Planning phase**: Opus — needs architectural judgment about module boundaries
- **Implementation chunks**: Sonnet — mechanical extraction once boundaries decided
- **Review**: Opus — verify no behavior changes, clean module interfaces

## Workflow Instructions

1. Read this file
2. Read `app/Main.hs` in full
3. Plan the extraction (write chunks below)
4. Get user approval
5. Implement chunk by chunk, each leaving tests green
6. Update Progress below after each chunk

## Analysis

### Current Main.hs Breakdown (516 LOC)

| Lines     | LOC | Function / Block                  | Category           | Verdict       |
|-----------|-----|-----------------------------------|--------------------|---------------|
| 1-55      |  55 | Imports                           | Plumbing           | Stays (shrinks after extraction) |
| 57-58     |   2 | `c_exit` FFI import              | Plumbing           | Stays         |
| 60-68     |   9 | `main`                            | Plumbing           | Stays         |
| 73-109    |  37 | `handleUncaughtException` + `handleAwsError` | Error handling | Move          |
| 115-325   | 211 | `runCommand` (dispatch)           | Mixed              | Stays (shrinks) |
| 334-380   |  47 | `runCfnWithArgs`                  | Orchestration      | Move          |
| 383-387   |   5 | `createSimpleContext`             | Orchestration      | Move          |
| 390-393   |   4 | `timeProviderForOperation`       | Business logic     | Move          |
| 396-401   |   6 | `cliToAwsSettings`               | CLI conversion     | Move          |
| 404-418   |  15 | `generateToken`                  | Token generation   | Move          |
| 421-430   |  10 | `emitsCommandMetadata`           | Business logic     | Move          |
| 433-435   |   3 | `handleEither`                   | Utility            | Move          |
| 438-440   |   3 | `exitCode`                       | Utility            | Stays         |
| 443-447   |   5 | `detectShellType`                | CLI helper         | Move to Cli   |
| 450-453   |   4 | `dieTxt`                         | Utility            | Move          |
| 460-516   |  57 | Shell completion scripts          | Static data        | Move to Cli   |

### Extraction Destinations

| What to extract                          | Destination module           | Rationale                                       |
|------------------------------------------|------------------------------|-------------------------------------------------|
| `runCfnWithArgs`                         | **Iidy.Cfn.Runner** (NEW)    | Core orchestration; biggest single block        |
| `createSimpleContext`                     | **Iidy.Cfn.Runner**          | Same orchestration concern                       |
| `emitsCommandMetadata`                   | **Iidy.Cfn.Runner**          | Couples to runCfnWithArgs metadata logic         |
| `cliToAwsSettings`                       | **Iidy.Cli** (existing)      | Pure CLI type conversion                         |
| `generateToken`                          | **Iidy.Aws.ClientReqToken**  | Token concern lives there already                |
| `timeProviderForOperation`               | **Iidy.Aws.Timing** (existing) | Provider selection logic belongs with providers |
| `handleUncaughtException` + `handleAwsError` | **Iidy.Errors** (NEW)   | Error formatting is reusable library logic       |
| `dieTxt` + `handleEither`               | **Iidy.Errors**              | Same error concern                               |
| `detectShellType`                        | **Iidy.Cli** (existing)      | CLI type; ShellType is already defined there     |
| Shell completion scripts                 | **Iidy.Cli.Completion** (NEW) | 57 LOC of static data, move out of app/          |

### Post-Refactor Main.hs Shape (~120 LOC estimated)

```haskell
module Main (main) where
-- ~15 lines of imports

main :: IO ()
-- ~8 lines: signal handler + parseCliOpts + runCommand + catch

runCommand :: Cli -> IO ()
-- ~100 lines: pattern match on Commands, each arm 2-5 lines
--   For CfnWithArgs ops: call Iidy.Cfn.Runner.runCfnWithArgs
--   For simple ops: call createSimpleContext + operation + handle result
--   For param ops: call createAwsEnvFromSettings + operation
--   For misc: call library directly

exitCode :: Int -> IO ()
-- 3 lines: stays (too small to extract)
```

The `runCommand` function stays in Main.hs because it is pure CLI dispatch logic --
it matches on the `Commands` ADT and calls into library functions. Each arm becomes
shorter once `runCfnWithArgs`, `createSimpleContext`, error helpers, etc. are
extracted.

## Chunks

### Chunk 1: Extract error utilities to `Iidy.Errors`

**Create** `src/Iidy/Errors.hs` with:
- `handleUncaughtException :: SomeException -> IO ()` (lines 73-93)
- `handleAwsError :: Amazonka.Error -> IO ()` (lines 96-109)
- `dieTxt :: Text -> IO a` (lines 450-453)
- `handleEither :: Either Text Int -> IO Int` (lines 433-435)

**Changes to Main.hs**:
- Remove these 4 functions
- Add `import Iidy.Errors (handleUncaughtException, dieTxt, handleEither)`

**Changes to cabal**:
- Add `Iidy.Errors` to `exposed-modules`

**LOC removed from Main.hs**: ~47
**LOC of new module**: ~55 (with header/imports)
**Risk**: Zero -- pure extraction, no logic changes.

---

### Chunk 2: Move `cliToAwsSettings` and `detectShellType` into `Iidy.Cli`

**Add to** `src/Iidy/Cli.hs`:
- `cliToAwsSettings :: Cli -> AwsSettings` (lines 396-401)
- `detectShellType :: String -> ShellType` (lines 443-447)

These are pure functions on CLI types already defined in `Iidy.Cli`. The module
currently has no dependency on `Iidy.Aws.CredentialSource` but will need one
for `AwsSettings`. This is acceptable because `CredentialSource` is a leaf
type module with no transitive dependencies.

**Changes to Main.hs**:
- Remove these 2 functions
- Update import of `Iidy.Cli` to include `cliToAwsSettings, detectShellType`
- Remove `import Iidy.Aws.CredentialSource (AwsSettings(..))` from Main.hs
  (if no longer needed directly)

**LOC removed from Main.hs**: ~11
**Risk**: Low -- adding one import to Iidy.Cli. Check for circular deps.

---

### Chunk 3: Move `generateToken` to `Iidy.Aws.ClientReqToken`

**Add to** `src/Iidy/Aws/ClientReqToken.hs`:
- `generateToken :: Cli -> IO TokenInfo` -- but this depends on `Cli`, which
  would create a dependency from Aws to Cli.

**Better approach**: Extract as `generateTokenFromMaybe :: Maybe Text -> IO TokenInfo`
that takes the optional user-provided token text instead of the full `Cli` type.
The Main.hs call site becomes:
```haskell
token <- generateTokenFromMaybe (aoClientRequestToken (cliAwsOpts cli))
```

This avoids a Cli dependency in the Aws module.

**Changes to Main.hs**:
- Remove `generateToken` (15 lines)
- Replace calls: `generateToken cli` -> `generateTokenFromMaybe (aoClientRequestToken (cliAwsOpts cli))`

**Changes to cabal**: None (module already exposed).

**New dependency for ClientReqToken**: `uuid` package (for `Data.UUID.V4.nextRandom`).
Verify it is already in the cabal `build-depends`. If not, add it.

**LOC removed from Main.hs**: ~15
**Risk**: Low -- refactoring the signature slightly. Verify uuid dep exists.

---

### Chunk 4: Move `timeProviderForOperation` to `Iidy.Aws.Timing`

**Add to** `src/Iidy/Aws/Timing.hs`:
- `timeProviderForOperation :: CfnOperation -> TimeProvider` (lines 390-393)

This function already uses `isReadOnlyOperation`, `systemTimeProvider`, and
`reliableTimeProvider` -- all defined in or accessible from `Iidy.Aws.Timing`.
The only new dependency is `Iidy.Cfn.Types (CfnOperation, isReadOnlyOperation)`.

**Check for circular deps**: `Iidy.Aws.Timing` currently has no Cfn imports.
Adding `Iidy.Cfn.Types` is safe because `Cfn.Types` is a pure data module with
no Aws dependencies.

**Changes to Main.hs**:
- Remove `timeProviderForOperation` (4 lines)
- Update import: `import Iidy.Aws.Timing (..., timeProviderForOperation)`

**LOC removed from Main.hs**: ~4
**Risk**: Low -- verify no circular dependency.

---

### Chunk 5: Extract shell completion scripts to `Iidy.Cli.Completion`

**Create** `src/Iidy/Cli/Completion.hs` with:
- `bashCompletionScript :: String` (lines 461-476)
- `zshCompletionScript :: String` (lines 478-499)
- `fishCompletionScript :: String` (lines 501-516)

**Changes to Main.hs**:
- Remove 3 script definitions
- Add `import Iidy.Cli.Completion (bashCompletionScript, zshCompletionScript, fishCompletionScript)`

**Changes to cabal**:
- Add `Iidy.Cli.Completion` to `exposed-modules`

**LOC removed from Main.hs**: ~57
**Risk**: Zero -- pure data extraction.

---

### Chunk 6: Extract `runCfnWithArgs`, `createSimpleContext`, `emitsCommandMetadata` to `Iidy.Cfn.Runner`

**Create** `src/Iidy/Cfn/Runner.hs` with:
- `runCfnWithArgs :: Cli -> CfnOperation -> Text -> Maybe Text -> (CfnContext -> StackArgs -> Maybe FilePath -> Text -> (OutputData -> IO ()) -> IO Int) -> IO ()` (lines 334-380)
- `createSimpleContext :: Cli -> CfnOperation -> IO CfnContext` (lines 383-387)
- `emitsCommandMetadata :: CfnOperation -> Bool` (lines 421-430)

These three functions form a cohesive "CFN command runner" concern. They
orchestrate AWS env setup, stack-args loading, context creation, metadata
emission, and final summary.

**Dependencies of the new module**:
- `Iidy.Cli` (for `Cli`, `GlobalOpts`, `cliToAwsSettings` -- after chunk 2)
- `Iidy.Aws.Config` (for `createAwsEnv`)
- `Iidy.Aws.ClientReqToken` (for `generateTokenFromMaybe` -- after chunk 3)
- `Iidy.Aws.Timing` (for `timeProviderForOperation` -- after chunk 4)
- `Iidy.Cfn.Context` (for `CfnContext`, `createContext`, `createContextFromEnv`)
- `Iidy.Cfn.CommandMetadata` (for `constructCommandMetadata`, `createFinalCommandSummary`)
- `Iidy.Cfn.StackArgsLoader` (for `loadStackArgs`, `LoadedStackArgs`)
- `Iidy.Cfn.GlobalConfig` (for `applyGlobalConfiguration`)
- `Iidy.Cfn.Types` (for `CfnOperation`, `StackArgs`)
- `Iidy.Output.Manager` (for `mkOutputDispatch`, `renderOutput`)
- `Iidy.Output.Types` (for `OutputData`)
- `Iidy.Errors` (for `dieTxt` -- after chunk 1)

**Changes to Main.hs**:
- Remove 3 functions (~62 lines)
- Add `import Iidy.Cfn.Runner (runCfnWithArgs, createSimpleContext, emitsCommandMetadata)`

**Changes to cabal**:
- Add `Iidy.Cfn.Runner` to `exposed-modules`

**LOC removed from Main.hs**: ~62
**Risk**: Medium -- largest extraction. Must verify all call sites in
`runCommand` still work with the same signatures. The function signatures
do not change, so this is a clean lift-and-shift.

---

### Chunk 7: Final cleanup and import pruning

After all extractions, Main.hs should be ~120-130 LOC. This chunk:
- Remove unused imports from Main.hs
- Verify build is clean (`-Wall -Wcompat` zero warnings)
- Run full test suite
- Review the `runCommand` dispatch -- some arms that use `createSimpleContext`
  + `mkOutputDispatch` + result handling could optionally be further compressed
  using a local helper, but this is cosmetic and optional

**LOC of final Main.hs**: ~120-130 (target: 100-150)

---

### Dependency Order

Chunks must be implemented in this order because of import dependencies:

```
Chunk 1 (Iidy.Errors)           -- no deps on other chunks
Chunk 2 (cliToAwsSettings)      -- no deps on other chunks
Chunk 3 (generateToken)         -- no deps on other chunks
Chunk 4 (timeProviderForOp)     -- no deps on other chunks
Chunk 5 (Completion scripts)    -- no deps on other chunks
   (Chunks 1-5 are independent; can be done in any order or parallel)
Chunk 6 (Iidy.Cfn.Runner)       -- depends on chunks 1-4 being done
Chunk 7 (Final cleanup)         -- depends on chunk 6
```

### LOC Budget

| Chunk | LOC removed from Main.hs | New module LOC |
|-------|--------------------------|----------------|
| 1     | ~47                      | ~55            |
| 2     | ~11                      | +11 to Cli.hs  |
| 3     | ~15                      | +20 to ClientReqToken.hs |
| 4     | ~4                       | +8 to Timing.hs |
| 5     | ~57                      | ~65            |
| 6     | ~62                      | ~80            |
| 7     | ~10 (import cleanup)     | 0              |
| **Total** | **~206**             |                |

Starting at 516 LOC, removing ~206 yields **~310 LOC**. That is over the
100-150 target. The remaining ~310 LOC is the `runCommand` dispatch function
(~211 LOC) plus `main` (9 LOC) + `exitCode` (3 LOC) + imports (~40 LOC) +
FFI decl (2 LOC).

### Optional Chunk 8: Compress `runCommand` dispatch

The `runCommand` dispatch is ~211 LOC because each "simple context" command
arm repeats the same pattern:
```haskell
CmdFoo args -> do
    ctx <- createSimpleContext cli OpFoo
    dispatch <- mkOutputDispatch (cliGlobalOpts cli)
    result <- fooOperation ctx ...
    case result of
      Left err -> dieTxt err
      Right rc -> exitCode rc
```

To further reduce, introduce a helper in `Iidy.Cfn.Runner`:
```haskell
runSimpleOp :: Cli -> CfnOperation -> (CfnContext -> (OutputData -> IO ()) -> IO (Either Text a)) -> (a -> IO ()) -> IO ()
```

This could compress each arm from 5-8 lines to 2-3 lines, saving another
~60-80 LOC. This is optional but would bring Main.hs to ~130 LOC.

Another variant for commands that also emit CommandMetadata+FinalSummary
(exec-changeset, delete-stack):
```haskell
runSimpleOpWithMeta :: Cli -> CfnOperation -> AwsSettings -> StackArgs -> Text
                    -> (CfnContext -> (OutputData -> IO ()) -> IO (Either Text Int))
                    -> IO ()
```

This is a judgment call. The repeated pattern is real, but the variations
between arms (different result types, different env/emit threading) may
make a single helper awkward. The implementer should evaluate after chunks
1-7 whether the remaining dispatch code benefits from further abstraction.

## Progress

- [x] Plan: read Main.hs, design module boundaries, write chunks
- [x] Chunk 1: Extract error utilities to Iidy.Errors
- [x] Chunk 2: Move cliToAwsSettings + detectShellType into Iidy.Cli
- [x] Chunk 3: Move generateToken to Iidy.Aws.ClientReqToken
- [x] Chunk 4: Move timeProviderForOperation to Iidy.Aws.Timing
- [x] Chunk 5: Extract shell completion scripts to Iidy.Cli.Completion
- [x] Chunk 6: Extract runCfnWithArgs + createSimpleContext to Iidy.Cfn.Runner
- [x] Chunk 7: Final cleanup and import pruning
- [x] (Optional) Chunk 8: Skipped — dispatch at 295 LOC is clean pattern-matching, no abstraction needed
- [x] Build clean + all tests pass (1243 tests, zero warnings)

## Handoff Notes

**Planning session**: 2026-03-01, Opus 4.6.

**Key decisions**:
1. `generateToken` gets a signature change to `generateTokenFromMaybe :: Maybe Text -> IO TokenInfo`
   to avoid adding a `Cli` dependency to `Iidy.Aws.ClientReqToken`. The call site
   adapts by extracting the `Maybe Text` from `Cli` before calling.
2. `handleUncaughtException` goes to a new `Iidy.Errors` module rather than
   `Iidy.Output` because it uses `hPutStrLn stderr` directly (not the output
   pipeline) and handles Amazonka errors specifically.
3. Shell completion scripts get their own module `Iidy.Cli.Completion` because
   they are 57 LOC of pure static strings with no dependencies.
4. `emitsCommandMetadata` moves with `runCfnWithArgs` to `Iidy.Cfn.Runner`
   because it is used exclusively by `runCfnWithArgs` and couples to its
   metadata emission logic.
5. Chunks 1-5 are independent and safe to implement in parallel (or delegate
   to parallel Sonnet sub-agents). Chunk 6 depends on all of 1-4.
6. The target of ~100-150 LOC requires the optional chunk 8 (dispatch compression).
   Without it, Main.hs lands around ~310 LOC. Whether to pursue chunk 8 depends
   on how clean the remaining dispatch looks after chunk 7.

**Implementation session**: 2026-03-03, Opus 4.6. Session 2026-03-03--19.
All chunks 1-7 implemented in a single commit (12d7d87). Main.hs went from
564 LOC to 295 LOC. Chunk 8 (dispatch compression) not pursued — the remaining
runCommand dispatch is clean pattern-matching that doesn't benefit from
further abstraction.
