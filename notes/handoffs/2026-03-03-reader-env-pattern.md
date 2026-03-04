# ReaderT Pattern for CFN Operation Threading

**Date**: 2026-03-03 (research), 2026-03-04 (proposal)
**Decision**: Use `ReaderT CfnEnv IO` (concrete, no Has-classes, no mtl/rio deps)

---

## Audit Summary

### The 6-Parameter Callback

Every CFN operation dispatched through `runCfnWithArgs` receives:

```haskell
(RemoteImports -> CfnContext -> StackArgs -> Maybe FilePath -> Text -> (OutputData -> IO ()) -> IO Int)
```

| Pos | Type                    | Name             | Read-only? | Scope        |
|-----|-------------------------|------------------|------------|--------------|
| 1   | `RemoteImports`         | remoteImports    | Yes        | Session      |
| 2   | `CfnContext`            | ctx              | Yes*       | Session      |
| 3   | `StackArgs`             | sa               | Yes        | Per-operation|
| 4   | `Maybe FilePath`        | argsfilePath     | Yes        | Per-operation|
| 5   | `Text`                  | env              | Yes        | Session      |
| 6   | `OutputData -> IO ()`   | emit             | Yes        | Session      |

\* `CfnContext.cfnUsedTokens` is an `IORef` — mutated via `ctxDeriveToken` but that's fine inside ReaderT.

### What Goes in the ReaderT Env

4 of 6 params are **session-scoped** (same for entire CLI invocation). These go into the env:
- `CfnContext` — AWS client, tokens, timing
- `Text` (environment name) — from `--environment` flag
- `RemoteImports` — from `--no-remote-imports` flag
- `OutputData -> IO ()` — output emitter closure

2 of 6 params are **per-operation** and stay as explicit args:
- `StackArgs` — loaded from argsfile, unique per invocation
- `Maybe FilePath` — argsfile path for template resolution

### Threading Depth

```
Runner.runCfnWithArgs
  └─ operation (createStack, updateStack, ...)     ← 6 params
       └─ RequestBuilder (build*Request)           ← 6 params (same set)
            └─ TemplateLoader.loadCfnTemplate      ← ImportConfig (built from env)
                 └─ Engine.preprocessYaml11         ← LoadImportFn (closure, stays in IO)
```

Only 2 levels of pure passthrough (operation → RequestBuilder). But the benefit is in extensibility — adding a new env field requires 0 signature changes vs. 10+ files today.

### Two Tiers of Operations

**Tier 1 — via `runCfnWithArgs`** (all get the uniform 6-param bundle):
createStack, updateStack, createOrUpdate, createChangeset, estimateCost, lintTemplate, templateApprovalRequest

**Tier 2 — via `createSimpleContext`** (ad-hoc params, no StackArgs):
deleteStack, describeStack, watchStack, describeStackDrift, listStacks, getStackTemplate, convertStackToIidy, templateApprovalReview, executeChangeset

Both tiers benefit from `CfnM` — Tier 2 operations that take `ctx + emit` drop to just their unique params.

---

## Concrete Design

### New Module: `src/Iidy/Cfn/Env.hs`

```haskell
module Iidy.Cfn.Env (
    CfnEnv (..),
    CfnM,
    runCfnM,
    askContext,
    askEnvName,
    askRemoteImports,
    emitOutput,
    mkImportConfig,
) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader (ReaderT, asks, runReaderT)
import Data.Text (Text)

import Iidy.Cfn.Context (CfnContext (..))
import Iidy.Output.Types (OutputData)
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..))
import Iidy.Yaml.Imports.Types (RemoteImports)

data CfnEnv = CfnEnv
    { ceContext       :: !CfnContext
    , ceEnvironment   :: !Text
    , ceRemoteImports :: !RemoteImports
    , ceEmit          :: !(OutputData -> IO ())
    }

type CfnM = ReaderT CfnEnv IO

runCfnM :: CfnEnv -> CfnM a -> IO a
runCfnM = flip runReaderT

askContext :: CfnM CfnContext
askContext = asks ceContext

askEnvName :: CfnM Text
askEnvName = asks ceEnvironment

askRemoteImports :: CfnM RemoteImports
askRemoteImports = asks ceRemoteImports

emitOutput :: OutputData -> CfnM ()
emitOutput od = do
    f <- asks ceEmit
    liftIO (f od)

mkImportConfig :: CfnM ImportConfig
mkImportConfig = do
    ctx <- askContext
    ri  <- askRemoteImports
    pure ImportConfig { icAwsEnv = Just (cfnEnv ctx), icRemoteImports = ri }
```

### Before / After: `createStack`

**Before (6 params):**
```haskell
createStack ::
    CfnContext -> StackArgs -> Maybe FilePath -> Text ->
    (OutputData -> IO ()) -> RemoteImports -> IO (Either Text Int)
createStack ctx args argsfilePath env emit remoteImports = do
    reqResult <- buildCreateStackRequest ctx args True argsfilePath env remoteImports
    case reqResult of
        Left err -> pure (Left err)
        Right (req, _token) -> do
            resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req
            let stackName = saStackName args
                stackId = fromMaybe stackName resp.stackId
            emitStackDefinition ctx stackId emit
            emit (OdPollingStarted "Loading live events...")
            ...
```

**After (2 params):**
```haskell
createStack :: StackArgs -> Maybe FilePath -> CfnM (Either Text Int)
createStack args argsfilePath = do
    reqResult <- buildCreateStackRequest args True argsfilePath
    case reqResult of
        Left err -> pure (Left err)
        Right (req, _token) -> do
            ctx <- askContext
            resp <- liftIO $ runResourceT $ Amazonka.send (cfnEnv ctx) req
            let stackName = saStackName args
                stackId = fromMaybe stackName resp.stackId
            liftIO $ emitStackDefinition ctx stackId  -- or convert emitStackDefinition too
            emitOutput (OdPollingStarted "Loading live events...")
            ...
```

### Before / After: `buildCreateStackRequest`

**Before (6 params):**
```haskell
buildCreateStackRequest ::
    CfnContext -> StackArgs -> Bool -> Maybe FilePath -> Text ->
    RemoteImports -> IO (Either Text (CF.CreateStack, TokenInfo))
buildCreateStackRequest ctx args usePrimary argsfilePath env remoteImports = do
    let importCfg = ImportConfig{icAwsEnv = Just (cfnEnv ctx), icRemoteImports = remoteImports}
    token <- if usePrimary then pure (cfnPrimaryToken ctx) else ctxDeriveToken ctx "create-stack"
    tmplEither <- loadCfnTemplate (saTemplate args) argsfilePath env importCfg
    ...
```

**After (3 params):**
```haskell
buildCreateStackRequest ::
    StackArgs -> Bool -> Maybe FilePath -> CfnM (Either Text (CF.CreateStack, TokenInfo))
buildCreateStackRequest args usePrimary argsfilePath = do
    ctx       <- askContext
    env       <- askEnvName
    importCfg <- mkImportConfig
    token <- liftIO $
        if usePrimary then pure (cfnPrimaryToken ctx) else ctxDeriveToken ctx "create-stack"
    tmplEither <- liftIO $ loadCfnTemplate (saTemplate args) argsfilePath env importCfg
    ...
```

### Before / After: `runCfnWithArgs` callback type

**Before:**
```haskell
(RemoteImports -> CfnContext -> StackArgs -> Maybe FilePath -> Text -> (OutputData -> IO ()) -> IO Int)
```

**After:**
```haskell
(StackArgs -> Maybe FilePath -> CfnM Int)
```

### Before / After: Runner dispatch

**Before:**
```haskell
rc <- action remoteImports ctx sa' (Just argsfilePath) env emit
    `finally` cleanupOutputDispatch dispatch
```

**After:**
```haskell
let cfnEnv = CfnEnv
        { ceContext       = ctx
        , ceEnvironment   = env
        , ceRemoteImports = remoteImports
        , ceEmit          = emit
        }
rc <- runCfnM cfnEnv (action sa' (Just argsfilePath))
    `finally` cleanupOutputDispatch dispatch
```

### Tier 2 Operations (Simple Context)

Operations using `createSimpleContext` construct a `CfnEnv` directly:

```haskell
-- In Main.hs dispatch for CmdDeleteStack:
ctx <- createSimpleContext cli OpDeleteStack
dispatch <- mkOutputDispatch (cliGlobalOpts cli)
let cfnEnv = CfnEnv
        { ceContext       = ctx
        , ceEnvironment   = goEnvironment (cliGlobalOpts cli)
        , ceRemoteImports = BlockRemoteImports  -- unused by delete
        , ceEmit          = renderOutput dispatch
        }
runCfnM cfnEnv (deleteStack stackName skipConfirm)
```

### Boundary: YAML Engine stays in IO

`TemplateLoader.loadCfnTemplate` stays in `IO` — it takes `ImportConfig` (built from env) and returns `IO (Either Text TemplateResult)`. The Engine below it uses `LoadImportFn` closures. No need for ReaderT there.

```
CfnM ──── runCfnM boundary ────
  │
  ├── Operations (CfnM)
  │     └── RequestBuilder (CfnM)
  │           └── loadCfnTemplate (IO, via liftIO)
  │                 └── preprocessYaml11 (IO, LoadImportFn closure)
  │
  └── StackOperations (IO, called via liftIO)
        └── pollForCompletion, collectStackContents, etc.
```

Functions like `pollForCompletion`, `collectStackContents` can stay in IO and be called via `liftIO`, or be converted to `CfnM` incrementally. Not all need conversion in the first pass.

---

## Trade-offs

| Aspect                    | Explicit params (current)                | ReaderT CfnEnv (proposed)                    |
|---------------------------|------------------------------------------|----------------------------------------------|
| Adding a new env field    | Touch 10+ function signatures            | Add field to CfnEnv, `asks` where needed     |
| Data flow visibility      | grep-friendly, all params in signature   | Must check CfnEnv definition + `asks` calls  |
| Boilerplate per operation | 6-param signature + passthrough          | 2-param signature, env implicit              |
| Testing                   | Pass 6 args to each function             | Construct CfnEnv once, `runCfnM`             |
| Dependencies              | None (already have transformers)         | None (use transformers ReaderT directly)      |
| Monad constraints         | Pure IO                                  | CfnM (= ReaderT CfnEnv IO), liftIO needed   |
| Migration effort          | N/A                                      | ~15 files, mechanical refactor               |

---

## Implementation Plan

### Phase 1: Core + CreateStack vertical slice
1. Create `src/Iidy/Cfn/Env.hs` with `CfnEnv`, `CfnM`, helpers
2. Convert `RequestBuilder.buildCreateStackRequest` to `CfnM`
3. Convert `Operations/CreateStack.hs` to `CfnM`
4. Update `Runner.runCfnWithArgs` — construct `CfnEnv`, `runCfnM`
5. Update `app/Main.hs` dispatch for `CmdCreateStack`
6. Fix tests — green commit

### Phase 2: Remaining Tier 1 operations
7. Convert `buildUpdateStackRequest`, `buildCreateChangeSetRequest`
8. Convert UpdateStack, CreateOrUpdate, Changeset, EstimateCost, LintTemplate, TemplateApproval
9. Green commit

### Phase 3: Tier 2 operations (optional, incremental)
10. Convert deleteStack, describeStack, watchStack, etc.
11. Convert `createSimpleContext` callers in Main.hs
12. Green commit

### Phase 4: Cleanup
13. Remove unused parameter-threading helpers
14. Update tests for `CfnEnv` construction patterns

---

## Files Changed

| File                                         | Change                                          |
|----------------------------------------------|-------------------------------------------------|
| `src/Iidy/Cfn/Env.hs`                       | **NEW** — CfnEnv, CfnM, helpers                |
| `src/Iidy/Cfn/Runner.hs`                    | Construct CfnEnv, callback type change          |
| `src/Iidy/Cfn/RequestBuilder.hs`            | All build* → CfnM (except buildDeleteStackReq)  |
| `src/Iidy/Cfn/Operations/CreateStack.hs`    | CfnM                                            |
| `src/Iidy/Cfn/Operations/UpdateStack.hs`    | CfnM                                            |
| `src/Iidy/Cfn/Operations/CreateOrUpdate.hs` | CfnM                                            |
| `src/Iidy/Cfn/Operations/Changeset.hs`      | CfnM (createChangeset, describeChangeset)        |
| `src/Iidy/Cfn/Operations/EstimateCost.hs`   | CfnM                                            |
| `src/Iidy/Cfn/Operations/LintTemplate.hs`   | CfnM                                            |
| `src/Iidy/Cfn/Operations/TemplateApproval.hs`| CfnM                                           |
| `src/Iidy/Cfn/Operations/DeleteStack.hs`    | CfnM (Phase 3)                                  |
| `src/Iidy/Cfn/Operations/DescribeStack.hs`  | CfnM (Phase 3, helpers used by Tier 1)          |
| `src/Iidy/Cfn/Operations/WatchStack.hs`     | CfnM (Phase 3)                                  |
| `app/Main.hs`                                | Dispatch updates, CfnEnv construction            |
| `iidy-hs.cabal`                              | Expose new module                                |
| `test/` (multiple)                           | CfnEnv construction in test harnesses            |

### Unchanged
- `src/Iidy/Yaml/Engine.hs` — stays in IO
- `src/Iidy/Yaml/Imports/` — stays in IO (LoadImportFn closure boundary)
- `src/Iidy/Cfn/TemplateLoader.hs` — stays in IO (takes ImportConfig)
- `src/Iidy/Cfn/StackOperations.hs` — stays in IO (poll/collect helpers)
- `src/Iidy/Cfn/Context.hs` — CfnContext type unchanged
