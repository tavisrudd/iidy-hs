# Widen CfnContext + Bundle StackInput (Threading Reduction)

**Date**: 2026-03-04
**Status**: Ready to implement
**Predecessor**: ReaderT experiment (reverted — see findings below)

---

## Background: ReaderT Experiment

Session 2026-03-04--1 fully implemented a `ReaderT CfnEnv IO` monad
(`CfnM`) for all Tier 1 CFN operations. The patch is saved at
`notes/patches/0001-Introduce-ReaderT-based-CfnM-monad-for-CFN-operation.patch`.

### What we learned

The ReaderT approach **compiled, passed all 1246 tests, and was
zero-warning clean**. But after evaluation:

| Aspect               | ReaderT result                                              |
|----------------------|-------------------------------------------------------------|
| Net line change      | **+290 lines** (579 ins / 289 del) — codebase got bigger    |
| liftIO noise         | Nearly every IO call in operation bodies needed wrapping     |
| Context extraction   | `ctx <- askContext; emitFn <- askEmit; liftIO $ helper ctx stackId emitFn` is MORE boilerplate than the old `helper ctx stackId emit` where both were already parameters |
| Threading depth      | Only **2 levels** (operation → RequestBuilder). ReaderT shines at 5+. |
| Grep-friendliness    | Lost — can't read a signature to see dependencies           |
| Extensibility        | Real win: new env field = 1 type change + 1 `asks` call    |

**Verdict**: Marginal benefit, net negative on readability. Reverted.

### Better approach: widen CfnContext + bundle StackInput

The threading problem is real, but the solution is simpler: **put the
missing fields directly into `CfnContext`** (which already gets threaded
everywhere) and **bundle the two per-operation params into a record**.

---

## Design

### Step 1: Widen CfnContext

Add 3 fields to `CfnContext` (`src/Iidy/Cfn/Context.hs`):

```haskell
data CfnContext = CfnContext
    { cfnEnv                :: !Amazonka.Env
    , cfnCredentialSources  :: !CredentialSourceStack
    , cfnTimeProvider       :: !TimeProvider
    , cfnStartTime          :: !UTCTime
    , cfnPrimaryToken       :: !TokenInfo
    , cfnUsedTokens         :: !(IORef [TokenInfo])
    , cfnOperation          :: !CfnOperation
    -- new fields:
    , cfnEnvironment        :: !Text               -- from --environment flag
    , cfnRemoteImports      :: !RemoteImports       -- from --no-remote-imports
    , cfnEmit               :: !(OutputData -> IO ()) -- output emitter
    }
```

These are all session-scoped, read-only, and already available at
`CfnContext` construction time in `Runner.runCfnWithArgs`.

### Step 2: Bundle per-operation inputs

```haskell
-- In Iidy.Cfn.Types or a new small module
data StackInput = StackInput
    { siArgs     :: !StackArgs
    , siArgsFile :: !(Maybe FilePath)
    }
```

### Step 3: Simplified signatures

**Before (6 params):**
```haskell
createStack :: CfnContext -> StackArgs -> Maybe FilePath -> Text
            -> (OutputData -> IO ()) -> RemoteImports -> IO (Either Text Int)
```

**After (2 params):**
```haskell
createStack :: CfnContext -> StackInput -> IO (Either Text Int)
```

No monad transformer. No `liftIO`. Same grep-friendliness. Same IO.

### Step 4: Runner callback type

**Before:**
```haskell
(RemoteImports -> CfnContext -> StackArgs -> Maybe FilePath -> Text -> (OutputData -> IO ()) -> IO Int)
```

**After:**
```haskell
(CfnContext -> StackInput -> IO Int)
```

Or even simpler — Runner constructs CfnContext with the new fields and
packages StackInput, so the callback is just:

```haskell
runCfnWithArgs cli op argsfile stackNameOverride $ \ctx input ->
    createStack ctx input >>= handleEither
```

### Step 5: RequestBuilder

Same pattern. Before: 6 params. After: `ctx` + `args` + `usePrimary` + `argsfilePath`.

Actually, `argsfilePath` and `env` are now accessible from `ctx`, so:

```haskell
buildCreateStackRequest :: CfnContext -> StackArgs -> Bool -> Maybe FilePath
                        -> IO (Either Text (CF.CreateStack, TokenInfo))
```

The `Maybe FilePath` stays explicit because it's per-operation data (the argsfile path
for template resolution). `env` and `remoteImports` come from `ctx`.

Or with `StackInput`:
```haskell
buildCreateStackRequest :: CfnContext -> StackInput -> Bool
                        -> IO (Either Text (CF.CreateStack, TokenInfo))
```

### Tier 2 operations

Operations that use `createSimpleContext` (deleteStack, watchStack, etc.)
already take `CfnContext` as their first param. The new fields will be
populated in `createSimpleContext` as well (or with defaults for fields
that don't apply, like `RemoteImports = BlockRemoteImports` for delete).

---

## Files to change

| File                                          | Change                                              |
|-----------------------------------------------|-----------------------------------------------------|
| `src/Iidy/Cfn/Context.hs`                    | Add 3 fields to CfnContext, update constructors     |
| `src/Iidy/Cfn/Types.hs`                      | Add StackInput record                               |
| `src/Iidy/Cfn/Runner.hs`                     | Populate new CfnContext fields, build StackInput    |
| `src/Iidy/Cfn/RequestBuilder.hs`             | Drop env/remoteImports params, read from ctx        |
| `src/Iidy/Cfn/Operations/CreateStack.hs`     | Drop 4 params, use ctx fields                       |
| `src/Iidy/Cfn/Operations/UpdateStack.hs`     | Same                                                |
| `src/Iidy/Cfn/Operations/CreateOrUpdate.hs`  | Same                                                |
| `src/Iidy/Cfn/Operations/Changeset.hs`       | Same (createChangeset)                              |
| `src/Iidy/Cfn/Operations/EstimateCost.hs`    | Same                                                |
| `src/Iidy/Cfn/Operations/LintTemplate.hs`    | Same                                                |
| `src/Iidy/Cfn/Operations/TemplateApproval.hs`| Same (templateApprovalRequest)                      |
| `app/Main.hs`                                | Simplify all runCfnWithArgs callbacks               |

No new modules. No new dependencies. Net line count should **decrease**.

---

## Implementation notes

- `createContext` and `createContextFromEnv` need the new params.
  Add them to the end of the param list and update the 2 call sites
  (Runner.runCfnWithArgs and Runner.createSimpleContext).

- `createSimpleContext` doesn't have an emitter or env name. Two options:
  (a) Accept them as params, (b) Use a separate constructor.
  Option (a) is simpler — Main.hs already constructs `dispatch`/`emit`
  before calling Tier 2 operations. Thread them into `createSimpleContext`.

- `ImportConfig` construction currently happens in RequestBuilder:
  `ImportConfig{icAwsEnv = Just (cfnEnv ctx), icRemoteImports = remoteImports}`.
  With `cfnRemoteImports` in CfnContext, this becomes:
  `ImportConfig{icAwsEnv = Just (cfnEnv ctx), icRemoteImports = cfnRemoteImports ctx}`.
  Could add a helper `ctxImportConfig :: CfnContext -> ImportConfig` to Context.hs.

- The `StackInput` record is optional polish. Even without it, just
  widening `CfnContext` reduces signatures from 6 params to 3
  (ctx, args, argsfilePath). That's already a big win.

## Delegation

- **Delegatable?** Yes — mechanical refactor, Sonnet can handle it
- **Prerequisite**: Read this doc + the patch for reference
- **Estimated scope**: 1 session, 1-2 commits
