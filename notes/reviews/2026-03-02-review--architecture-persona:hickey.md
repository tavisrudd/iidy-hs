# Architecture Review: Rich Hickey Lens

_"Simplicity is a prerequisite for reliability." — Edsger Dijkstra_
_"Simple made easy." — Rich Hickey_

Hickey's central question: **What have you braided together that should be independent?**
The word is _complect_ — from Latin _complectere_, to braid together.

---

## 1. CfnContext: Seven Concerns in a Trenchcoat

```haskell
data CfnContext = CfnContext
  { cfnEnv               :: !Amazonka.Env            -- AWS client
  , cfnCredentialSources :: !CredentialSourceStack   -- display provenance
  , cfnTimeProvider      :: !TimeProvider             -- NTP or system
  , cfnStartTime         :: !UTCTime                  -- elapsed timer
  , cfnPrimaryToken      :: !TokenInfo                -- idempotency
  , cfnUsedTokens        :: !(IORef [TokenInfo])      -- mutable accumulator
  , cfnOperation         :: !CfnOperation             -- which op
  }
```

This record complects:

| Concern                | Used by                        | Needed when                  |
|------------------------|--------------------------------|------------------------------|
| AWS client (`cfnEnv`)  | Every Amazonka.send call       | Always                       |
| Credential provenance  | CommandMetadata display only   | Start of write ops only      |
| Time source            | Context creation, elapsed calc | Start + end                  |
| Start time             | Elapsed calculation            | End of op                    |
| Primary token          | RequestBuilder                 | Request construction         |
| Used tokens (IORef)    | CommandMetadata summary        | End of op only               |
| Operation identity     | One `cfnOperationStr` call     | Metadata display             |

`cfnCredentialSources` exists solely so `CommandMetadata` can print "Credential: Environment Variables (static)". It's display logic smuggled into the execution context. `cfnOperation` exists for a single `Text` conversion. The `IORef` forces the entire context into IO — you can't even _read_ a `CfnContext` in pure code because the IORef contaminates the type.

**What's braided:** execution client + display metadata + timing + identity + mutable state.

**Unbraiding:** The AWS `Env` should flow separately from the display-only provenance. Token tracking could be a return value from operations rather than mutation. Operation identity shouldn't be in the context at all — the caller already knows what it called.

---

## 2. StackArgs: The 21-Maybe Bag (PARTIALLY ADDRESSED)

```haskell
data StackArgs = StackArgs
  { saStackName                   :: !(Maybe Text)
  , saTemplate                    :: !(Maybe Text)
  , saCapabilities                :: !(Maybe [Text])
  , saTags                        :: !(Maybe (Map Text Text))
  , saParameters                  :: !(Maybe (Map Text Text))
  , saOnFailure                   :: !(Maybe Text)    -- ← stringly typed
  , saDisableRollback             :: !(Maybe Bool)
  , ...                                               -- 21 fields, all Maybe
  }
```

This complects "what the user wrote in YAML" with "what an operation needs." Every CFN operation receives the full 21-field record and cherry-picks 3-8 fields, silently ignoring the rest. `createStack` doesn't use `saUsePreviousTemplate`. `deleteStack` uses only `saStackName`. The type can't tell you.

Worse: `saOnFailure :: Maybe Text` when the actual domain is `DO_NOTHING | ROLLBACK | DELETE`. The serialization representation has leaked into the domain type. Similarly `saCapabilities` is `Maybe [Text]` when CloudFormation defines exactly four capability values.

**What's braided:** deserialization schema + domain type + operation-specific field subsets.

---

## 3. Five Error Handling Strategies, One Codebase (PARTIALLY ADDRESSED)

The error story is a braid of five incompatible patterns:

| Pattern              | Example site                        | Mechanism                              |
|----------------------|-------------------------------------|----------------------------------------|
| `Either Text`        | All CFN operations                  | Structured, composable                 |
| `try @SomeException` | Http.hs, GlobalConfig.hs, Params    | Catch-all, type-erasing                |
| `catch` + stderr     | Sts.hs:28, Render.hs:54            | Side-effecting fallback                |
| `fail`               | TemplateLoader.hs:76,83,97         | Exception disguised as IO failure      |
| `throwIO`            | StackOperations.hs:78              | Re-throw after inspection              |

The `Either Text` pattern is clean. But `fail` in `TemplateLoader` throws `IOError`s that propagate to the top-level `catch` in Main.hs — these are the same kind of error that other modules return as `Left`. A caller can't know which modules return errors and which throw them without reading the source.

`SomeException` catching in `GlobalConfig` and `Timing` silently swallows errors. The NTP client discards the exception entirely (`catch \(_ :: SomeException) -> pure Nothing`). This isn't error handling — it's error hiding.

**What's braided:** structured errors + exception throwing + silent swallowing + stderr side-effects. Five different answers to "what happens when something goes wrong" in one codebase.

---

## 4. OValue / Value: The Parallel Universe

The codebase maintains two complete value representations:

```
OValue  — ordered keys ([(Text, OValue)])    — used by: emitter, resolver output
Value   — unordered keys (KeyMap Value)      — used by: Handlebars, JMESPath, StackArgsLoader
```

The resolver outputs `OValue`. To call `applyJmesPath`, you convert to `Value`. The result comes back as `Value`. You convert back to `OValue`. This conversion boundary runs through the middle of the resolution pipeline:

```
resolveAst :: TagContext -> YamlAst -> Either ResolveError OValue
  internally: toValue queriedVal -> applyJmesPath query -> fromValue result
```

The two types exist because Aeson's `Value` doesn't preserve key order and CloudFormation templates need it. Fair. But the cost is that every consumer must know which representation they're in, and the conversion boundary is invisible — `toValue` loses information (key order), `fromValue` preserves it (because aeson-2.x happens to use ordered keymaps internally, but this is an implementation detail).

**What's braided:** key-order preservation + JSON ecosystem compatibility. The system pays conversion tax at every boundary because two value types are complected into a single pipeline.

---

## 5. The Emit Callback: Output Woven Through Everything

Every CFN operation takes `(OutputData -> IO ())`:

```haskell
createStack  :: CfnContext -> StackArgs -> Maybe FilePath -> Text -> (OutputData -> IO ()) -> IO (Either Text Int)
updateStack  :: CfnContext -> StackArgs -> Maybe FilePath -> Text -> (OutputData -> IO ()) -> IO (Either Text Int)
deleteStack  :: CfnContext -> Text -> Bool -> Text -> (OutputData -> IO ()) -> IO (Either Text Int)
watchStack   :: CfnContext -> Text -> Int -> (OutputData -> IO ()) -> IO (Either Text Int)
```

This is callback-driven output — the operation decides _when_ to emit, and the callback decides _how_ to render. Clean separation? Partly. But:

1. The callback is threaded through 4 layers: Main -> Operation -> StackOperations -> PollConfig callbacks. Every intermediate function must accept and forward `emit`.
2. Several modules bypass the callback entirely — `Sts.hs` writes warnings directly to stderr via `hPutStrLn`, `Render.hs` writes errors to stderr via `TIO.hPutStr`. So the "all output goes through the pipeline" invariant is a lie.
3. `OdRawOutput !Text` is an escape hatch — it says "I don't know what structure this output has, just print the text." This defeats the purpose of having 27 structured variants.

**What's braided:** output structure + output routing + operation sequencing. Operations can't execute without an output strategy. You can't test an operation's _logic_ without providing a renderer.

---

## 6. StackArgsLoader: YAML is the Domain

```haskell
resolveEnvMaps :: Value -> Text -> Either Text Value
ensureEnvironmentTag :: Value -> Text -> Value
injectEnvValues :: Value -> Text -> CfnOperation -> AwsSettings -> Value
buildEnvValues :: Text -> CfnOperation -> AwsSettings -> Value
valueToStackArgs :: Value -> Either Text StackArgs
```

Every function in this module pattern-matches on `Value` constructors (`Object`, `String`, `Array`). Business logic — "add an environment tag", "resolve per-environment profile overrides" — is expressed as `KM.lookup`, `KM.insert`, `KM.fromList`. The serialization format _is_ the intermediate representation.

The pipeline is: `ByteString -> YamlAst -> OValue -> Value -> [4 Value transforms] -> StackArgs`. The data goes through three format changes before reaching the domain type. Each conversion is a place where the wrong format's assumptions can leak in.

**What's braided:** YAML schema knowledge + AWS domain logic + aeson data manipulation.

---

## 7. Terminal Statuses: Stringly Typed State Machines

```haskell
allTerminalStatuses :: [Text]
allTerminalStatuses =
  [ "CREATE_COMPLETE", "CREATE_FAILED"
  , "DELETE_COMPLETE", "DELETE_FAILED"
  , "ROLLBACK_COMPLETE", "ROLLBACK_FAILED"
  , ...
  ]
```

Stack statuses are `Text` everywhere — in `StackDefinition.sdStatus`, in `StackEvent.seResourceStatus`, in terminal-status lists, in success-state checks. The compiler can't distinguish `"CREATE_COMPLETE"` from `"CREATE_COMPLTEE"`. Pattern matching on status is string comparison. The state machine of stack lifecycle transitions is implicit in scattered `elem` checks.

Amazonka actually provides `StackStatus` as a proper sum type. But the codebase converts it to `Text` immediately (at the amazonka boundary) and works with strings throughout.

**What's braided:** status identity + string representation + state machine transitions.

---

## 8. InteractiveRenderer: The God Record

```haskell
data InteractiveRenderer = InteractiveRenderer
  { irStdout             :: !Handle            -- I/O target
  , irStderr             :: !Handle            -- I/O target
  , irOptions            :: !InteractiveOptions -- configuration
  , irColorScheme        :: !ColorScheme        -- theming
  , irTerminalWidth      :: !Int               -- layout
  , irIsTty              :: !Bool              -- capability
  , irHasRenderedContent :: !(IORef Bool)       -- render state
  , irSpinner            :: !(TVar (Maybe Spinner))    -- animation
  , irSpinnerThread      :: !(TVar (Maybe ThreadId))  -- thread mgmt
  , irTimingState        :: !(TVar ...)               -- timing
  , irTimingThread       :: !(TVar (Maybe ThreadId))  -- thread mgmt
  }
```

Six distinct concerns in one record: I/O targets, configuration, theming, layout, animation lifecycle, and concurrent thread management. Every render function receives this record and touches a different subset. The spinner state is only relevant during polling. The timing thread is only relevant during long operations. But they're always present, always allocated.

**What's braided:** output destination + visual configuration + terminal capability detection + mutable render state + concurrent animation + timing.

---

## 9. runCfnWithArgs: The 50-Line Sequence

```haskell
runCfnWithArgs cli operation argsfile stackNameOverride action = do
  -- parse
  -- dispatch
  -- load stack args
  -- create AWS env
  -- apply global config
  -- override stack name
  -- generate token
  -- select time provider
  -- create context
  -- maybe emit metadata
  -- run action
  -- maybe emit summary
  -- exit
```

This function complects: configuration loading, AWS bootstrapping, global config application, name overriding, token generation, time provider selection, context creation, metadata emission, action execution, summary emission, and exit code handling. It's a 50-line procedural script in IO with no intermediate checkpoints. You can't reuse "load args and create context" without also getting metadata emission and exit code handling.

**What's braided:** configuration + bootstrapping + execution + reporting + process lifecycle.

---

## Summary: The Complecting Inventory

| # | What's complected                                         | Severity | Where                          |
|---|-----------------------------------------------------------|----------|--------------------------------|
| 1 | AWS client + display metadata + timing + mutable tokens   | High     | CfnContext                     |
| 2 | YAML schema + domain type + operation field subsets        | High     | StackArgs, StackArgsLoader     |
| 3 | 5 incompatible error handling strategies                   | High     | Across codebase                |
| 4 | Key-order preservation + JSON ecosystem                    | Medium   | OValue/Value dual              |
| 5 | Output structure + routing + operation sequencing          | Medium   | emit callback threading        |
| 6 | Serialization format + business logic                      | Medium   | StackArgsLoader                |
| 7 | Status identity + string representation                    | Medium   | Terminal statuses as Text       |
| 8 | 6 concerns in one renderer record                          | Medium   | InteractiveRenderer            |
| 9 | Config + bootstrap + execute + report + exit               | Low      | runCfnWithArgs                 |

---

## What's Actually Simple

Credit where due. Several things are genuinely unbraided:

- **The YAML resolver is pure.** `resolveAst :: TagContext -> YamlAst -> Either ResolveError OValue` — no IO, no mutation, no callbacks.
- **Handlebars and JMESPath are pure.** `interpolate` and `applyJmesPath` take values, return values. No effects.
- **The JSON Schema validator is pure.** `validateSchema :: Value -> Value -> Either Text ()`.
- **CLI types are pure data.** `Iidy.Cli` defines ADTs with no IO imports. Parsing is separate from execution.
- **The YAML engine's two-phase split** (IO loading then pure resolution) is a clean separation.
- **Import dispatch via `LoadImportFn`** — function injection rather than a typeclass. Simple, testable.
- **No circular dependencies.** The module DAG is strictly layered.

The pure core is well-isolated. The complecting happens at the boundaries — where configuration meets execution, where domain types meet serialization, where output threading meets operation logic.

As Hickey would say: the simple parts are genuinely simple. The complected parts aren't _complex_ in the "hard to build" sense — they're complex in the "hard to change independently" sense. And that's exactly the kind of complexity that compounds over time.

---

## Post-Review Status Updates (Session 46, 2026-03-02)

_These annotations were added after the review to track which findings have been addressed._

| #   | Finding                                    | Status              | Notes                                                                                                                                                      |
| --- | ------------------------------------------ | ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | CfnContext: seven concerns braided         | OPEN                | No changes to CfnContext structure. Architectural observation acknowledged but refactoring deferred.                                                        |
| 2   | StackArgs: 21-Maybe bag, stringly typed    | PARTIALLY ADDRESSED | `saOnFailure` → `Maybe OnFailure` ADT; `saCapabilities` → `Maybe [Capability]` ADT; `saStackName` → non-optional `!Text` (1E); unknown-key validation with did-you-mean suggestions (1D). Per-operation field subset issue remains (4C). |
| 3   | Five error handling strategies             | PARTIALLY ADDRESSED | TemplateLoader `fail` → `Either Text` (6 sites). `try @SomeException` narrowed to specific types at 13 AWS boundaries (3A). GlobalConfig catches `Amazonka.Error` not `SomeException` (1G). Reduced from 5 strategies to 3. |
| 4   | OValue/Value parallel universe             | OPEN                | No changes to the dual value representation or conversion boundaries. Architectural observation acknowledged.                                               |
| 5   | Emit callback threading                    | OPEN                | No structural changes to the callback threading pattern. `OdRawOutput` (added in Session 42) was noted here as a concern — it remains as an escape hatch.  |
| 6   | StackArgsLoader: YAML is the domain        | OPEN                | No changes to the Value-based transform pipeline in StackArgsLoader.                                                                                       |
| 7   | Terminal statuses: stringly typed           | RESOLVED            | `StackStatus` ADT with 22 constructors replaces `Text` throughout (4A). All predicates pattern-match on the ADT. Amazonka types converted at boundary via `fromCfnStackStatus`/`fromCfnResourceStatus`. |
| 8   | InteractiveRenderer: god record            | OPEN                | No structural changes to the renderer record.                                                                                                              |
| 9   | runCfnWithArgs: 50-line sequence           | OPEN                | No decomposition of the monolithic orchestration function.                                                                                                 |
