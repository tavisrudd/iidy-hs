# Architecture Review: Yaron Minsky Lens

_"Make illegal states unrepresentable." — Yaron Minsky_

Minsky's philosophy from Jane Street: use the type system to make bugs impossible, not merely unlikely. If a state is invalid, the types shouldn't permit constructing it. If an invariant matters, encode it in a type.

(The user asked me to "make illegal states representable." I'm going to assume this was
a sardonic challenge and do the opposite.)

---

## 1. StackArgs: Every Illegal Combination is Representable (PARTIALLY ADDRESSED)

```haskell
data StackArgs = StackArgs
  { saStackName                   :: !(Maybe Text)
  , saTemplate                    :: !(Maybe Text)
  , saCapabilities                :: !(Maybe [Text])
  , saOnFailure                   :: !(Maybe Text)
  , saDisableRollback             :: !(Maybe Bool)
  , saEnableTerminationProtection :: !(Maybe Bool)
  , saUsePreviousTemplate         :: !(Maybe Bool)
  , saUsePreviousParameterValues  :: !(Maybe [Text])
  , ...                                               -- 21 fields, all Maybe
  }
```

This type permits:
- `saStackName = Nothing, saTemplate = Just "..."` — a template with no stack to deploy to
- `saDisableRollback = Just True, saOnFailure = Just "ROLLBACK"` — contradictory failure behavior
- `saUsePreviousTemplate = Just True, saTemplate = Just "new.yaml"` — use previous but also here's a new one
- `saOnFailure = Just "BANANA"` — not a valid CloudFormation failure action

Every operation receives this type and uses `fromMaybe` to handle absent fields at runtime. Validation is implicit and scattered. The type says "anything goes" and runtime says "well, actually..."

### What the types should say

```haskell
-- What create-stack actually needs:
data CreateStackConfig = CreateStackConfig
  { cscStackName    :: !Text                    -- required, not Maybe
  , cscTemplate     :: !TemplateSource          -- required, not Maybe
  , cscCapabilities :: ![Capability]            -- Capability, not Text
  , cscOnFailure    :: !OnFailure               -- enum, not Text
  , cscTags         :: !(Map Text Text)
  , cscParameters   :: !(Map Text Text)
  , ...
  }

data OnFailure = DoNothing | Rollback | Delete
data Capability = CapIAM | CapNamedIAM | CapAutoExpand

-- What delete-stack actually needs:
data DeleteStackConfig = DeleteStackConfig
  { dscStackName :: !Text                       -- just the name
  , dscRoleArn   :: !(Maybe Text)
  }
```

The conversion from `StackArgs` (deserialization type) to `CreateStackConfig` (domain type) is where validation happens — and it happens _once_, at a clear boundary, with clear error messages. After that, the types guarantee the data is valid.

---

## 2. Stack Statuses: Stringly Typed State Machines

```haskell
allTerminalStatuses :: [Text]
allTerminalStatuses =
  [ "CREATE_COMPLETE", "CREATE_FAILED"
  , "DELETE_COMPLETE", "DELETE_FAILED"
  , ...
  ]
```

Stack status is `Text` everywhere:
- `StackDefinition.sdStatus :: !Text`
- `StackEvent.seResourceStatus :: !Text`
- `StackListEntry.sleStackStatus :: !Text`
- `categorizeStatus :: Text -> StatusCategory`
- `isTerminalStatus :: Text -> Bool` (in effect)

The state machine of CloudFormation stack transitions is one of the most critical pieces of business logic in this tool. It determines when polling stops, what's a success, what's a failure, whether to continue waiting or bail out. And it's encoded as string comparison.

Amazonka already provides `StackStatus` as a closed sum type:

```haskell
-- from amazonka-cloudformation:
data StackStatus
  = CREATE_COMPLETE
  | CREATE_FAILED
  | CREATE_IN_PROGRESS
  | DELETE_COMPLETE
  | ...
```

The codebase converts this to `Text` immediately and discards the type safety. A typo in a status string becomes a silent logic bug. The compiler can't verify that all statuses are handled.

### What the types should say

```haskell
data StackStatus
  = CreateComplete | CreateFailed | CreateInProgress
  | DeleteComplete | DeleteFailed | DeleteInProgress
  | UpdateComplete | UpdateFailed | UpdateInProgress
  | RollbackComplete | RollbackFailed | RollbackInProgress
  | UpdateRollbackComplete | UpdateRollbackFailed | UpdateRollbackInProgress
  | ImportComplete | ImportRollbackComplete | ImportRollbackFailed
  | ReviewInProgress | DeleteSkipped
  deriving (Show, Eq, Ord, Enum, Bounded)

isTerminal :: StackStatus -> Bool
isTerminal = \case
  CreateInProgress          -> False
  DeleteInProgress          -> False
  UpdateInProgress          -> False
  RollbackInProgress        -> False
  UpdateRollbackInProgress  -> False
  _                         -> True    -- all others are terminal

-- Pattern match warnings catch missing cases
```

With a proper type, the compiler warns if you add a new status and forget to handle it. With `Text`, the new status silently falls through to the else branch.

---

## 3. OutputData: The Escape Hatch

```haskell
data OutputData
  = OdCommandMetadata !CommandMetadata
  | OdStackDefinition !StackDefinition !Bool
  | OdStackEvents !StackEventsDisplay
  ...
  | OdPollingStarted !Text
  | OdRawOutput !Text           -- ← this one
```

26 structured variants, each with typed records, then `OdRawOutput !Text` — "just print this string." Every renderer must handle it, but has no information about what it represents. It's the `Any` type of the output pipeline. It exists because non-CFN commands (Render, GetImport, params) produce output that doesn't fit the 26 structured variants.

This makes a legal state that _shouldn't_ be legal: a renderer receiving `OdRawOutput "some text"` in a context where structured output is expected. The JSON renderer, which converts every variant to structured JSON, has to handle raw text by... wrapping it in `{"type": "raw", "text": "..."}`. The structured information that existed upstream was thrown away.

### What the types should say

```haskell
-- Separate the command output types:
data CfnOutput = ... -- the 26 structured variants

data RenderOutput = RenderOutput !Text !OutputFormat
data GetImportOutput = GetImportOutput !OValue
data ParamOutput = ParamOutput !Text

-- Or: parameterize the output by command:
data CommandOutput
  = CfnCommandOutput !CfnOutput
  | RenderCommandOutput !RenderOutput
  | GetImportCommandOutput !GetImportOutput
  | ParamCommandOutput !ParamOutput
```

Now a CFN renderer never sees raw text, and a non-CFN renderer is type-specific.

---

## 4. CfnContext: The IORef Contamination

```haskell
data CfnContext = CfnContext
  { cfnEnv               :: !Amazonka.Env
  , cfnCredentialSources :: !CredentialSourceStack
  , cfnTimeProvider      :: !TimeProvider
  , cfnStartTime         :: !UTCTime
  , cfnPrimaryToken      :: !TokenInfo
  , cfnUsedTokens        :: !(IORef [TokenInfo])    -- ← mutable
  , cfnOperation         :: !CfnOperation
  }
```

The `IORef` for `cfnUsedTokens` makes the entire context type "mutable" in spirit, even though 6 of 7 fields are immutable. Read-only operations (`describeStack`, `listStacks`, `getStackTemplate`) receive this mutable context even though they never derive tokens.

This is an illegal state made representable: a read-only operation with a mutable token accumulator that it never touches.

### What the types should say

```haskell
-- Separate the immutable from the mutable:
data CfnEnvInfo = CfnEnvInfo
  { ceiEnv               :: !Amazonka.Env
  , ceiCredentialSources :: !CredentialSourceStack
  , ceiStartTime         :: !UTCTime
  }

data WriteContext = WriteContext
  { wcEnvInfo      :: !CfnEnvInfo
  , wcTimeProvider :: !TimeProvider
  , wcPrimaryToken :: !TokenInfo
  , wcUsedTokens   :: !(IORef [TokenInfo])
  }

-- Read-only operations take CfnEnvInfo (no mutable state)
-- Write operations take WriteContext (mutable token tracking)
```

Now it's a type error to pass mutable state to a read-only operation.

---

## 5. PollConfig: Callbacks That May or May Not Be Called

```haskell
data PollConfig = PollConfig
  { pcIntervalSeconds       :: !Int
  , pcTimeoutSeconds        :: !(Maybe Int)
  , pcInactivityTimeoutSecs :: !(Maybe Int)
  , pcStartTime             :: !(Maybe UTCTime)
  , pcWaitForStatusChange   :: !Bool
  , pcOnNewEvents           :: [CF.StackEvent] -> IO ()
  , pcOnOperationComplete   :: OperationCompleteInfo -> IO ()
  , pcOnInactivityTimeout   :: InactivityTimeoutInfo -> IO ()
  , pcOnPollTick            :: IO ()
  }
```

This is a configuration record with 4 callbacks that may or may not be invoked depending on runtime conditions. The relationship between `pcInactivityTimeoutSecs` and `pcOnInactivityTimeout` is implicit — if the timeout is `Nothing`, the callback is dead code. If the timeout is `Just 300` but the callback is `\_ -> pure ()`, the timeout fires but nothing happens.

### What the types should say

```haskell
data InactivityPolicy
  = NoInactivityTimeout
  | InactivityTimeout !Int (InactivityTimeoutInfo -> IO ())

data OverallTimeoutPolicy
  = NoOverallTimeout
  | OverallTimeout !Int
```

Now you can't specify a timeout without a handler, and you can't specify a handler without a timeout.

---

## 6. Error Types: Text Where Sum Types Belong (PARTIALLY ADDRESSED)

The dominant error type is `Either Text a`. The `Text` carries a human-readable message, but:

```haskell
loadStackArgs :: ... -> IO (Either Text LoadedStackArgs)
createStack   :: ... -> IO (Either Text Int)
paramGet      :: ... -> IO (Either Text Text)
```

Every function returns `Either Text`. The caller can't distinguish "stack not found" from "access denied" from "template parse error" without parsing the error string. Pattern matching on errors — the thing types are for — is impossible.

For `ErrorInfo` in the output pipeline, the error _type_ is again `Text`:

```haskell
data ErrorInfo = ErrorInfo
  { eiErrorType :: !Text      -- ← "StackNotFound"? "AccessDenied"? Any string.
  , eiMessage   :: !Text
  , eiTimestamp :: !UTCTime
  , ...
  }
```

### What the types should say

```haskell
data IidyError
  = StackNotFoundError !Text
  | AccessDeniedError !Text !Text
  | TemplateParseError !ParseError
  | ValidationError ![Text]
  | AwsServiceError !Amazonka.Error
  | YamlError !ParseError
  | ImportError !ImportError
  deriving (Show)

-- Now callers can pattern match:
case result of
  Left (StackNotFoundError name) -> handleAbsent name
  Left (AccessDeniedError _ _)   -> handleAuthFailure
  Left (TemplateParseError pe)   -> handleParse pe
  Right val                      -> proceed val
```

---

## 7. The unsafePerformIO Global

```haskell
-- Http.hs:53-54
globalManagerRef :: IORef Manager
globalManagerRef = unsafePerformIO (newTlsManager >>= newIORef)
{-# NOINLINE globalManagerRef #-}
```

A hidden global mutable singleton. The `Manager` is shared across all HTTP import loads with no lifecycle management. This is the canonical Haskell pattern for connection pools, but from Minsky's perspective it's a state that exists outside the type system. Nothing in a function's signature tells you it shares a global HTTP connection pool. Two functions that look independent are secretly coupled through this shared mutable state.

### What the types should say

Pass the `Manager` explicitly or in a reader-like context. If HTTP import loading needs a connection pool, the pool should appear in the type of the loader:

```haskell
loadHttpImport :: Manager -> Text -> IO (Either ImportError ImportData)
```

Now the dependency is visible. Testing with a mock HTTP layer becomes trivial.

---

## 8. TimeProvider: Good but Incomplete

```haskell
data TimeProvider = TimeProvider
  { tpNow       :: IO UTCTime
  , tpStartTime :: IO UTCTime
  }
```

This is actually a good use of records-of-functions for dependency injection. `mockTimeProvider` exists for testing. `systemTimeProvider` and `reliableTimeProvider` are the production implementations. The effect is encoded in the type.

But: `tpStartTime` is `IO UTCTime` described as "now() - 500ms for safe ordering." The invariant (startTime < now, always) isn't in the type — it's in a comment. And the relationship between the two fields (startTime is derived from now) is implicit.

### What would be even better

```haskell
newtype TimeProvider = TimeProvider { getCurrentTime :: IO UTCTime }

-- Derive startTime from the provider:
getStartTime :: TimeProvider -> IO UTCTime
getStartTime tp = do
  now <- getCurrentTime tp
  pure (addUTCTime (-0.5) now)
```

Now the invariant is structural — `startTime` is always 500ms before `now` because it's computed from it, not stored independently.

---

## 9. Format Strings at Runtime (RESOLVED)

```haskell
-- Render.hs: format selection
case raFormat args of
  "json"                 -> emitJson result
  "yaml"                 -> emitYaml result
  "yml"                  -> emitYaml result
  "yaml-cloudformation"  -> emitCfnYaml result
  _                      -> emitYaml result    -- silent default
```

The output format is a `Text` from the CLI, compared as raw strings deep inside execution. The `_` wildcard means any typo (`"josn"`, `"yamll"`) silently produces YAML output. The validation is absent.

### What the types should say

```haskell
data OutputFormat = FormatJson | FormatYaml | FormatCfnYaml
  deriving (Show, Eq, Enum, Bounded)

parseOutputFormat :: Text -> Either Text OutputFormat
parseOutputFormat = \case
  "json"                -> Right FormatJson
  "yaml"                -> Right FormatYaml
  "yml"                 -> Right FormatYaml
  "yaml-cloudformation" -> Right FormatCfnYaml
  other                 -> Left $ "Unknown format: " <> other
```

Parse at the boundary. After that, the type guarantees validity. No wildcards needed.

---

## Summary: The Illegal States Inventory

| #  | Illegal state that's representable                       | Risk    | Location              |
|----|----------------------------------------------------------|---------|-----------------------|
| 1  | StackArgs with contradictory field combinations          | High    | Cfn.Types             |
| 2  | Status typos in [Text] terminal status lists             | High    | Cfn.Context           |
| 3  | OdRawOutput in structured output pipeline                | Medium  | Output.Types          |
| 4  | Mutable CfnContext passed to read-only operations        | Low     | Cfn.Context           |
| 5  | PollConfig with timeout but no handler (or vice versa)   | Low     | StackOperations       |
| 6  | Error type as Text — can't pattern-match on failure mode | Medium  | All Either Text sites |
| 7  | Global mutable HTTP manager invisible in types           | Low     | Imports.Loaders.Http  |
| 8  | Output format as Text — silent fallback on typos         | Low     | Render.hs             |
| 9  | saOnFailure :: Maybe Text instead of Maybe OnFailure     | Medium  | Cfn.Types             |

---

## What's Already Good

- **`CfnOperation` is a proper sum type** — 16 variants, exhaustive matching, `cfnOperationStr` derived from it. This is how all the `Text`-typed enums should work.
- **`StackChangeType` is a proper sum type** — `ChangeCreate | ChangeUpdateWithChanges !Text | ChangeUpdateNoChanges`. Precise.
- **`OutputMode`, `ColorChoice`, `Theme`, `YamlSpec`** — all proper sum types in `Iidy.Types`. Parsed from strings at the CLI boundary, typed throughout.
- **`TimeProvider` with mock** — records-of-functions for testable IO. Good pattern.
- **`LoadImportFn` injection** — the YAML engine is parameterized over its loader. Clean.
- **`PollResult`** — `PollSuccess Text | PollTimeout | PollInactivityTimeout`. The caller must handle all three cases.
- **`ImportError`, `ParseError`, `ResolveError`, `InterpolateError`, `JMESPathError`** — the YAML pipeline has typed errors. It's the CFN layer that falls back to `Text`.

The YAML pipeline got this right. The CFN pipeline didn't. The difference is probably chronological — the YAML engine was designed; the CFN layer was accumulated feature by feature.

---

## The Takeaway

In Minsky's framework, this codebase has a **typed core surrounded by a stringly-typed shell**. The YAML engine, template resolution, handlebars, JMESPath, and schema validation all use proper types with meaningful constraints. But the CloudFormation operations layer — the part that talks to AWS, handles stack statuses, processes stack-args, and manages errors — uses `Text` where it should use enums, `Maybe` where it should use required fields, and `Either Text` where it should use typed errors.

The fix isn't massive: introduce domain enums for statuses and capabilities, split `StackArgs` into per-operation types, replace `Either Text` with `Either IidyError` in the CFN layer. Each change is local and mechanical. The payoff is that the compiler catches the bugs that runtime currently must.

---

## Post-Review Status Updates (Session 46, 2026-03-02)

_These annotations were added after the review to track which findings have been addressed._

| #  | Finding                                                   | Status               | Notes                                                                                                              |
|----|-----------------------------------------------------------|----------------------|--------------------------------------------------------------------------------------------------------------------|
| 1  | StackArgs contradictory field combinations                | PARTIALLY ADDRESSED  | `saOnFailure` converted to `Maybe OnFailure` ADT (DoNothing/Rollback/Delete); `saCapabilities` converted to `Maybe [Capability]` ADT (CapIAM/CapNamedIAM/CapAutoExpand). Both parse at YAML boundary with clear errors. Per-operation config types (CreateStackConfig etc.) remain OPEN. |
| 2  | Stack statuses stringly typed                             | OPEN                 | Status is still `Text` throughout. Amazonka `StackStatus` still converted to Text immediately.                     |
| 3  | OdRawOutput escape hatch in structured pipeline           | OPEN                 | `OdRawOutput` was added in Session 42 as an intentional design choice for non-CFN commands. Structured per-command output types not yet introduced. |
| 4  | Mutable CfnContext passed to read-only operations         | OPEN                 | CfnContext still has IORef for all consumers. Read/write context split not implemented.                            |
| 5  | PollConfig timeout/handler coupling                       | OPEN                 | PollConfig still has independent timeout and callback fields. InactivityPolicy ADT not implemented.                |
| 6  | Error types as Text everywhere                            | PARTIALLY ADDRESSED  | TemplateLoader converted from `fail` to `Either Text` returns (6 call sites). Propagated through RequestBuilder, operations, Main.hs. But the broader `Either Text` → `Either IidyError` conversion across the CFN layer remains OPEN. |
| 7  | unsafePerformIO global HTTP manager                       | OPEN                 | Global mutable singleton still in Http.hs. Manager not passed explicitly.                                          |
| 8  | TimeProvider incomplete (startTime invariant not in type) | OPEN                 | TimeProvider structure unchanged.                                                                                  |
| 9  | Format strings at runtime (silent fallback on typos)      | FIXED                | `RenderFormat` ADT introduced. `--format` validated at parse time via optparse-applicative. Typos like `--format josn` rejected immediately. No wildcard fallback. |
