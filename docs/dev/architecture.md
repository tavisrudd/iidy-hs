# iidy-hs Architecture

## Overview

iidy-hs is a Haskell port of [iidy](https://github.com/unbounce/iidy), a
CloudFormation preprocessor and deployer. It reads YAML "stack-args" files
that describe a CloudFormation deployment (template, parameters, tags, etc.),
preprocesses them through a custom YAML engine with imports, variable
resolution, handlebars interpolation, and custom tags, then drives
CloudFormation operations through the AWS API.

The codebase uses GHC 9.10 and amazonka 2.0. It
covers the full lifecycle: stack CRUD, changesets,
drift detection, SSM parameter management, template approval workflows, and
offline utilities (render, lint, explain, demo, init-stack-args, completion,
get-import, convert-stack-to-iidy).

The preprocessing language has a [PLT Redex formal specification](../../spec/README.md)
that serves as the executable ground truth for semantics. A snapshot-based
conformance test suite verifies the Haskell implementation agrees with the
spec on key drift-point behaviors (truthiness, merge ordering, path resolution,
escape, map_values binding).

Several subsystems are custom implementations rather than library wrappers:
JMESPath query evaluation, Handlebars template engine, and JSON Schema
Draft 7 validation. No
suitable Haskell libraries existed for these with the specific semantics iidy
requires.

## Pipeline

A typical write operation (create-stack, update-stack, etc.) flows through
the full pipeline:

```
                         iidy-hs Pipeline
  ================================================================

  CLI Parsing                  YAML Preprocessing
  (optparse-applicative)       (two-phase engine)
        |                            |
        v                            v
  +-----------+    +--------+   +---------+   +----------+
  | Cli.hs    |--->| Stack  |-->| Phase 1 |-->| Phase 2  |
  | Parser.hs |    | Args   |   | imports |   | tags +   |
  +-----------+    | Loader |   | + $defs |   | hbs      |
                   +--------+   +---------+   +----------+
                       |                           |
                       v                           v
                  +---------+               +-----------+
                  | Merged  |               | OValue    |
                  | AWS     |               | (ordered) |
                  | Settings|               +-----------+
                  +---------+                     |
                       |                          |
                       v                          v
                  +----------+    +--------------------------+
                  | CfnCtx   |--->| CloudFormation Operation |
                  | (env,    |    | (create, update, poll..) |
                  |  tokens, |    +--------------------------+
                  |  timing) |                |
                  +----------+                v
                                   +--------------------+
                                   | OutputDispatch     |
                                   | (emit OutputData)  |
                                   +---------+----------+
                                             |
                              +--------------+--------------+
                              |                             |
                              v                             v
                    +------------------+          +----------------+
                    | Interactive      |          | JSON           |
                    | Renderer         |          | Renderer       |
                    | (ANSI + spinner) |          | (structured)   |
                    +------------------+          +----------------+
```

Read-only commands (describe-stack, list-stacks, render, explain) skip the
preprocessing phase and go directly to the operation or utility module.

### Orchestration: Runner and Main

The `runCfnWithArgs` function in `Cfn/Runner.hs` is the primary orchestrator
for stack-args-based operations. It handles the full lifecycle:

```
runCfnWithArgs :: Cli -> CfnOperation -> Text -> Maybe Text
               -> (CfnContext -> StackInput -> IO Int) -> IO ()
```

1. Creates `OutputDispatch` from `GlobalOpts`
2. Bootstraps an AWS env by extracting raw Profile/Region/AssumeRoleARN from
   the argsfile YAML (before preprocessing) and merging with CLI settings
3. Calls `loadStackArgs` to preprocess and deserialize the argsfile
4. Applies global SSM configuration (`/iidy/` path) via `GlobalConfig`
5. Creates `CfnContext` with merged AWS env, time provider, and tokens
6. Emits `CommandMetadata` for write operations
7. Runs the operation callback
8. Emits `FinalCommandSummary` and exits

For operations that don't load stack args (describe-stack, watch-stack, etc.),
`Main.hs` creates a `CfnContext` directly via `createSimpleContext` and
dispatches to the appropriate operation module.

## Complete Module Hierarchy

### Top-level (`src/Iidy/`)

| Module           | Purpose                                                    |
|------------------|------------------------------------------------------------|
| `Cli.hs`         | Command and option types (`Commands`, `GlobalOpts`, etc.)  |
| `Cli/Parser.hs`  | optparse-applicative parser definition                     |
| `Cli/Completion.hs` | Shell completion scripts (bash, zsh, fish)              |
| `Cli/Help.hs`    | Help text utilities                                        |
| `Types.hs`       | Shared enums: `OutputMode`, `ColorChoice`, `Theme`, `YamlSpec` |
| `Constants.hs`   | Project-wide constants (poll intervals, timeouts, limits)  |
| `Confirm.hs`     | Shared confirmation prompt with TTY/ANSI detection         |
| `Errors.hs`      | Uncaught exception handler, AWS error formatting, `dieTxt` |
| `Errors/JMESPath.hs` | JMESPath CLI query error formatting                   |
| `Render.hs`      | `render` command implementation                            |
| `GetImport.hs`   | `get-import` command implementation                        |
| `Demo.hs`        | `demo` command (typing simulation, secret masking)         |
| `Explain.hs`     | `explain` command (error code documentation)               |
| `InitStackArgs.hs` | `init-stack-args` command (scaffold argsfile + template) |

### AWS Infrastructure (`src/Iidy/Aws/`)

| Module              | Purpose                                                 |
|---------------------|---------------------------------------------------------|
| `Config.hs`         | AWS env creation, region resolution, credential detection |
| `CredentialSource.hs` | Credential provenance ADT and `AwsSettings`           |
| `ClientReqToken.hs` | Idempotency token generation and SHA256-based derivation |
| `Sts.hs`            | `getCallerIdentity` for credential display              |
| `Timing.hs`         | `TimeProvider` abstraction with SNTP client for NTP sync |

### CloudFormation (`src/Iidy/Cfn/`)

| Module               | Purpose                                                 |
|----------------------|---------------------------------------------------------|
| `Types.hs`           | Core types: `CfnOperation`, `StackArgs`, `Capability`, etc. |
| `Context.hs`         | `CfnContext` record and creation helpers                |
| `Runner.hs`          | `runCfnWithArgs` orchestrator and `createSimpleContext` |
| `StackArgsLoader.hs` | Argsfile loading, preprocessing, deserialization        |
| `StackOperations.hs` | Shared stack ops: fetch, poll, content collection       |
| `RequestBuilder.hs`  | Converts `StackArgs` to amazonka API requests           |
| `CommandMetadata.hs` | Builds `CommandMetadata` and `FinalCommandSummary`      |
| `GlobalConfig.hs`    | Reads SSM `/iidy/` params for global configuration     |
| `Status.hs`          | `StackStatus` ADT with predicates and terminal sets     |
| `TemplateHash.hs`    | SHA256 template hashing and S3 URL utilities            |
| `TemplateLoader.hs`  | Template file loading (local, S3, inline)               |

### CloudFormation Operations (`src/Iidy/Cfn/Operations/`)

| Module                  | Commands                                      |
|-------------------------|-----------------------------------------------|
| `CreateStack.hs`        | create-stack                                  |
| `UpdateStack.hs`        | update-stack, update-stack --changeset        |
| `CreateOrUpdate.hs`     | create-or-update (5 paths)                    |
| `DeleteStack.hs`        | delete-stack                                  |
| `DescribeStack.hs`      | describe-stack                                |
| `WatchStack.hs`         | watch-stack                                   |
| `DescribeStackDrift.hs` | describe-stack-drift                          |
| `Changeset.hs`          | create-changeset, exec-changeset              |
| `ListStacks.hs`         | list-stacks                                   |
| `GetStackTemplate.hs`   | get-stack-template                            |
| `LintTemplate.hs`       | lint-template                                 |
| `EstimateCost.hs`       | estimate-cost                                 |
| `TemplateApproval.hs`   | template-approval request/review              |
| `ConvertStack.hs`       | convert-stack-to-iidy                         |

### YAML Preprocessing (`src/Iidy/Yaml/`)

| Module                       | Purpose                                          |
|------------------------------|--------------------------------------------------|
| `Ast.hs`                     | YAML AST with source metadata and tag nodes      |
| `Parser.hs`                  | YAML parser producing `YamlAst`                  |
| `OValue.hs`                  | Order-preserving value type                       |
| `Emitter.hs`                 | Custom YAML emitter preserving key order          |
| `Engine.hs`                  | Two-phase preprocessing orchestrator              |
| `Detection.hs`               | YAML 1.1 vs 1.2 spec detection heuristics        |
| `Location.hs`                | `Position` and `SourceLocation` types             |
| `PathTracker.hs`             | Tracks YAML document path during processing       |
| `JMESPath.hs`                | Custom JMESPath query evaluator                   |
| `Resolution/Resolver.hs`     | Phase 2 tag resolution engine                     |
| `Resolution/Context.hs`      | `TagContext` with variable scope                  |
| `Handlebars/Engine.hs`       | Handlebars template parser and interpolator        |
| `Handlebars/Helpers.hs`      | Built-in helpers (including case aliases)          |
| `Imports/Types.hs`           | Import type ADT and security model                |
| `Imports/Manifest.hs`        | Import record tracking for auditing               |
| `Imports/ContentParsing.hs`  | Shared YAML/JSON content parsing for loaders      |
| `Imports/Loaders/Dispatch.hs` | Routes imports to type-specific loaders           |
| `Imports/Loaders/File.hs`    | File and filehash import loader                   |
| `Imports/Loaders/Env.hs`     | Environment variable import loader                |
| `Imports/Loaders/Git.hs`     | Git ref import loader                             |
| `Imports/Loaders/Random.hs`  | Random value import loader                        |
| `Imports/Loaders/Cfn.hs`     | CloudFormation stack output import loader         |
| `Imports/Loaders/Ssm.hs`     | SSM parameter and path import loader              |
| `Imports/Loaders/S3.hs`      | S3 object import loader                           |
| `Imports/Loaders/Http.hs`    | HTTP/HTTPS import loader                          |
| `CustomResources/Expansion.hs` | `Custom::*` resource type expansion             |
| `CustomResources/JsonSchema.hs` | JSON Schema Draft 7 validator                  |
| `CustomResources/Params.hs`  | Custom resource parameter definitions             |
| `CustomResources/RefRewriting.hs` | Ref/GetAtt rewriting for custom resources    |
| `Errors/Enhanced.hs`         | Enhanced error types with source locations        |
| `Errors/Ids.hs`              | Numeric error code definitions                    |
| `Errors/Display.hs`          | Colored error rendering with caret indicators     |
| `Errors/Conversion.hs`       | Error conversion from internal to enhanced        |
| `Errors/Conversion/Guidance.hs` | Contextual guidance text for errors            |
| `Errors/Conversion/LineSearch.hs` | Source line searching for error display       |
| `Errors/Conversion/Location.hs` | Source location resolution                     |

### Output System (`src/Iidy/Output/`)

| Module                              | Purpose                                     |
|-------------------------------------|---------------------------------------------|
| `Types.hs`                          | `OutputData` sum type                       |
| `Manager.hs`                        | `OutputDispatch` creation and routing       |
| `Renderer.hs`                       | `OutputMode` enum and renderer selection    |
| `Renderers/Interactive.hs`          | ANSI terminal renderer with spinners        |
| `Renderers/Interactive/Sections.hs` | Section-based layout for interactive output |
| `Renderers/Interactive/Types.hs`    | Interactive renderer internal types         |
| `Renderers/Json.hs`                 | JSON renderer (one object per line)         |
| `Color.hs`                          | Color theme resolution                      |
| `Theme.hs`                          | Dark/light/plain/high-contrast themes       |
| `Spinner.hs`                        | Braille dot animation on background thread  |
| `Terminal.hs`                       | Terminal capability detection               |
| `Status.hs`                         | Status level rendering                      |

### SSM Parameters (`src/Iidy/Params/`)

| Module       | Purpose                                                       |
|--------------|---------------------------------------------------------------|
| `Client.hs`  | SSM operations: get, set, get-by-path, get-history            |
| `Review.hs`  | Interactive diff of pending vs. current parameter values      |

## CLI Parsing

Entry point: `app/Main.hs` dispatches parsed commands.
Parser: `src/Iidy/Cli/Parser.hs` defines the optparse-applicative parser.
Types: `src/Iidy/Cli.hs` defines all command and option types.

The `Commands` sum type has one constructor per CLI command (plus
`CmdCompletion`):

```haskell
data Commands
  = CmdCreateStack !CreateStackArgs
  | CmdUpdateStack !UpdateStackArgs
  | CmdCreateOrUpdate !UpdateStackArgs
  | CmdEstimateCost !StackFileArgs
  | CmdCreateChangeset !CreateChangeSetArgs
  | CmdExecChangeset !ExecChangeSetArgs
  | CmdDescribeStack !DescribeArgs
  | CmdWatchStack !WatchArgs
  | CmdDescribeStackDrift !DriftArgs
  | CmdDeleteStack !DeleteArgs
  | CmdGetStackTemplate !GetTemplateArgs
  | CmdGetStackInstances !GetStackInstancesArgs
  | CmdListStacks !ListArgs
  | CmdParam !ParamCommands
  | CmdTemplateApproval !ApprovalCommands
  | CmdRender !RenderArgs
  | CmdGetImport !GetImportArgs
  | CmdDemo !DemoArgs
  | CmdLintTemplate !LintTemplateArgs
  | CmdConvertStackToIidy !ConvertArgs
  | CmdInitStackArgs !InitStackArgs
  | CmdCompletion !(Maybe ShellType)
  | CmdExplain ![Text]
```

`CmdGetStackInstances` is a removed command that directs users to the AWS CLI.

`GlobalOpts` carries cross-cutting flags:

```haskell
data GlobalOpts = GlobalOpts
  { goEnvironment    :: !Text
  , goColor          :: !ColorChoice
  , goTheme          :: !Theme
  , goOutputMode     :: !(Maybe OutputMode)
  , goDebug          :: !Bool
  , goLogFullError   :: !Bool
  , goRemoteImports  :: !Bool
  }
```

`AwsOpts` carries AWS-specific CLI flags (region, profile, assume-role-arn,
client-request-token) which are normalized and merged with argsfile-level
settings during stack-args loading.

## Stack-Args Loading

File: `src/Iidy/Cfn/StackArgsLoader.hs`

The stack-args loader bridges the CLI and CloudFormation operations. It takes
a YAML argsfile path and produces a `LoadedStackArgs`:

```haskell
loadStackArgs
  :: FilePath           -- argsfile path
  -> Text               -- environment name
  -> CfnOperation       -- operation being performed
  -> AwsSettings        -- CLI-provided AWS settings
  -> RemoteImports      -- whether remote imports are allowed
  -> Maybe Amazonka.Env -- bootstrap AWS env for import processing
  -> IO (Either Text LoadedStackArgs)
```

The loading sequence:

1. Parse the argsfile YAML (YAML 1.1 mode for CloudFormation compatibility)
2. Preprocess through the YAML engine (resolve imports, custom tags, handlebars)
3. Resolve environment-specific maps for Profile, Region, AssumeRoleARN
4. Inject `$envValues` into the template variable scope
5. Deserialize to `StackArgs` (template path, parameters, tags, capabilities, etc.)
6. Merge CLI-level AWS settings with argsfile-level settings (CLI wins)

The result includes merged `AwsSettings` and a `CredentialDetectionContext`
that describes how credentials were resolved (for the metadata display).

## YAML Preprocessing

The preprocessing engine is the most complex subsystem. It transforms raw YAML
into a fully resolved `OValue` through a two-phase pipeline.

### Phase 1: Imports and Definitions

Files: `src/Iidy/Yaml/Imports/`, `src/Iidy/Yaml/Engine.hs`

Phase 1 walks the AST looking for `$imports` and `$defs` directives. Imports
are loaded via a pluggable `LoadImportFn` (file, env, git, random, filehash,
cfn, ssm, ssm-path, s3, http/https), and their results are merged into the
resolution context. Circular imports are detected and rejected. The import
dispatcher (`Loaders/Dispatch.hs`) routes each import type to its specialized
loader, with a security gate that prevents local-only imports from being
loaded within remote base templates.

### Phase 2: Tag Resolution and Handlebars

Files: `src/Iidy/Yaml/Resolution/Resolver.hs`, `src/Iidy/Yaml/Handlebars/Engine.hs`

Phase 2 resolves custom YAML tags and interpolates handlebars expressions.
The resolver walks the AST depth-first, processing each tagged node:

| Tag Category     | Tags                                                           |
|------------------|----------------------------------------------------------------|
| Variable access  | `!$` (lookup), `!$escape`                                      |
| Data loading     | `!$include`, `!$parseYaml`, `!$parseJson`                      |
| String ops       | `!$concat`, `!$join`, `!$split`, `!$replace`, `!$string`       |
| Conditionals     | `!$if`, `!$not`, `!$eq`                                        |
| Collections      | `!$merge`, `!$mergeMap`, `!$fromPairs`, `!$groupBy`            |
| Iteration        | `!$map`, `!$concatMap`, `!$mapListToHash`, `!$mapValues`       |
| Binding          | `!$let`, `!$expand`                                            |
| Queries          | `!$jmespath`, `!$jsonpath`                                     |
| Encoding         | `!$toJsonString`, `!$toYamlString`                             |
| CloudFormation   | `!$envValues`, `!$filehash`                                    |

Handlebars interpolation uses a custom engine with registered helpers
(including case-variant aliases):

| Category            | Helpers                                                      |
|---------------------|--------------------------------------------------------------|
| String case         | toLowerCase, toUpperCase, titleize, camelCase, pascalCase, snakeCase, kebabCase, capitalize |
| String manipulation | trim, replace, substring, length, pad, concat               |
| Encoding            | base64, urlEncode, sha256                                    |
| Serialization       | toJson/tojson, toJsonPretty/tojsonPretty, toYaml/toyaml     |
| Object access       | lookup                                                       |
| Comparison          | eq                                                           |

### OValue: Order-Preserving Values

File: `src/Iidy/Yaml/OValue.hs`

```haskell
data OValue
  = ONull
  | OBool !Bool
  | ONumber !Scientific
  | OString !Text
  | OArray ![OValue]
  | OObject ![(Text, OValue)]   -- insertion-ordered key-value pairs
```

`OValue` is used throughout the preprocessing pipeline instead of aeson's
`Value` type. The critical difference is `OObject`: it preserves insertion
order. CloudFormation templates must emit keys in a deterministic order
matching the source file, and the custom YAML emitter
(`src/Iidy/Yaml/Emitter.hs`) relies on this ordering.

Conversion between `OValue` and `Value` is provided by `toValue`/`fromValue`,
but `toValue` loses key ordering.

### YAML AST

File: `src/Iidy/Yaml/Ast.hs`

The parser produces a `YamlAst` that preserves source metadata (`SrcMeta`
with line/column positions) and distinguishes preprocessing tags
(`PreprocessingTag`), CloudFormation intrinsic tags
(`CloudFormationTag`), unknown tags, and imported document nodes. Each tag
variant carries its parsed arguments as a structured type (e.g., `IfTag`,
`MapTag`, `LetTag`).

### JMESPath

File: `src/Iidy/Yaml/JMESPath.hs`

Custom JMESPath implementation supporting the query operations iidy uses:
field access, nested/index expressions, projections, filters, multi-select
lists and hashes, pipes, and built-in functions (length, keys, values, sort,
join, etc.). Used by `!$jmespath` tags, `--query` CLI flags, and list-stacks
filtering.

### Custom Resources and JSON Schema

Files: `src/Iidy/Yaml/CustomResources/`

CloudFormation custom resources (`Custom::*` types) are expanded into their
`AWS::CloudFormation::CustomResource` equivalents. The expansion pipeline
rewrites resource types, normalizes properties, and handles Ref/GetAtt
rewriting. A custom JSON Schema Draft 7 validator
(`src/Iidy/Yaml/CustomResources/JsonSchema.hs`) validates resource schemas.

### YAML Spec Detection

File: `src/Iidy/Yaml/Detection.hs`

Auto-detects YAML version (1.1 vs 1.2) using heuristics: explicit `%YAML`
directives, CloudFormation key counting (e.g., `AWSTemplateFormatVersion`,
`Resources`), Kubernetes API detection, with fallback to YAML 1.2. This
affects boolean parsing (`on`/`off`/`yes`/`no` are booleans in 1.1 but
strings in 1.2).

## CloudFormation Operations

Directory: `src/Iidy/Cfn/`

### CfnContext

File: `src/Iidy/Cfn/Context.hs`

```haskell
data CfnContext = CfnContext
  { cfnEnv               :: !Amazonka.Env
  , cfnCredentialSources :: !CredentialSourceStack
  , cfnTimeProvider      :: !TimeProvider
  , cfnStartTime         :: !UTCTime
  , cfnPrimaryToken      :: !TokenInfo
  , cfnUsedTokens        :: !(IORef [TokenInfo])
  , cfnOperation         :: !CfnOperation
  , cfnEnvironment       :: !Text
  , cfnRemoteImports     :: !RemoteImports
  , cfnEmit              :: !(OutputData -> IO ())
  }
```

The monad stack is plain `IO` with `CfnContext` passed explicitly. This
mirrors the Rust source and avoids unnecessary transformer overhead for a CLI
tool with a linear execution path.

The `cfnEmit` callback is the output dispatch function, allowing operations
to emit structured `OutputData` without knowing which renderer is active.

### TimeProvider and NTP

File: `src/Iidy/Aws/Timing.hs`

```haskell
data TimeProvider = TimeProvider
  { tpStartTime   :: IO UTCTime
  , tpCurrentTime :: IO UTCTime
  }
```

The `TimeProvider` abstraction supports `systemTimeProvider` (uses
`getCurrentTime`), `reliableTimeProvider` (NTP-corrected via custom SNTP
client implementing RFC 4330), and `mockTimeProvider` (for testing). NTP
correction is important in CI environments where system clocks may drift.
Write operations use `reliableTimeProvider`; read-only operations use
`systemTimeProvider`.

### Credential Provenance

Files: `src/Iidy/Aws/CredentialSource.hs`, `src/Iidy/Aws/Config.hs`

Credentials are tracked through a `CredentialSource` ADT:

```haskell
data CredentialSource
  = EnvironmentVariablesStatic
  | EnvironmentVariablesTemporary
  | ProfileCredential !ProfileInfo
  | AssumeRoleCredential !AssumeRoleInfo
  | ContainerCredentialsEcs
  | ContainerCredentialsGeneric
  | WebIdentityToken
  | InstanceMetadata
  | UnknownCredentialSource
```

This provenance chain is displayed in `CommandMetadata` so operators can
verify which credentials a deployment used.

### Idempotency Tokens

File: `src/Iidy/Aws/ClientReqToken.hs`

CloudFormation client request tokens ensure idempotent retries. The primary
token is either user-provided (`--client-request-token`) or a random UUID.
Multi-step operations (e.g., create-or-update) derive deterministic
sub-tokens via SHA256 hashing of the primary token concatenated with a step
name, ensuring the same retry always produces the same derived token.

### Request Building

File: `src/Iidy/Cfn/RequestBuilder.hs`

Converts `StackArgs` + `CfnContext` into properly formatted amazonka API
requests:

```haskell
buildCreateStackRequest    :: CfnContext -> StackArgs -> ImportConfig -> IO CF.CreateStack
buildUpdateStackRequest    :: CfnContext -> StackArgs -> ImportConfig -> IO CF.UpdateStack
buildDeleteStackRequest    :: CfnContext -> Text -> DeleteArgs -> CF.DeleteStack
buildCreateChangeSetRequest :: CfnContext -> StackArgs -> Text -> Bool -> ImportConfig -> IO CF.CreateChangeSet
```

Handles template loading, parameter mapping, tag conversion, capability
mapping, token injection, and service role configuration.

### Polling and Event Streaming

File: `src/Iidy/Cfn/StackOperations.hs`

Write operations (create, update, delete) poll CloudFormation until the stack
reaches a terminal state. `pollForCompletion` drives the loop:

```haskell
pollForCompletion :: CfnContext -> Text -> [StackStatus] -> PollConfig -> IO PollResult
```

It takes a stack ID (use ARN for deletes), a list of terminal statuses, and a
`PollConfig` containing callbacks and timeout settings. It fetches events every
N seconds, emits new events via the `pcOnNewEvents` callback (as
`OdNewStackEvents`), detects inactivity timeouts, and returns a `PollResult`
containing the final stack status. A dependency-injected variant
`pollForCompletionWith` accepts a custom event-fetcher for testing.

The spinner runs on a background `forkIO` thread, ticking every 80ms.
This is the only use of concurrency in the codebase.

### Global SSM Configuration

File: `src/Iidy/Cfn/GlobalConfig.hs`

Before a CloudFormation operation runs, `applyGlobalConfiguration` reads SSM
parameters under the `/iidy/` path:

- `/iidy/default-notification-arn` -- SNS topic ARN appended to notification ARNs
- `/iidy/disable-template-approval` -- if `"true"`, clears approved template location

SSM errors are silently caught (no failure) since the common case is no
parameters existing.

### Confirmation Prompts

File: `src/Iidy/Confirm.hs`

```haskell
data ConfirmResult = Confirmed | Declined

requestConfirmation :: Text -> IO ConfirmResult
```

Shared confirmation prompt for destructive operations (delete-stack,
create-or-update). Displays with bold bright red ANSI formatting on TTYs,
defaults to "No" on non-TTY, and returns `Declined` for any input other
than `y`/`yes`.

### Constants

File: `src/Iidy/Constants.hs`

Project-wide constants including CFN poll intervals (2s default), poll
timeout (3600s), changeset creation timeout (300s), previous events count
(10), HTTP import timeout (30s), max HTTP response size (10MB), and regex
pattern length limit (1024).

## SSM Parameter Store

Files: `src/Iidy/Params/Client.hs`, `src/Iidy/Params/Review.hs`

Five SSM operations: `paramGet`, `paramSet`, `paramGetByPath`,
`paramGetHistory`, and `paramReview`. The review module provides an
interactive diff of pending (`.pending` suffix) vs. current parameter values
at a path, used in the approval workflow. Pagination is handled via
`Amazonka.paginate` with conduit-based resource management.

## Output System

Directory: `src/Iidy/Output/`

The output system is data-driven. All operation results flow through a single
`OutputData` sum type rather than performing direct I/O:

```haskell
data OutputData
  = OdCommandMetadata !CommandMetadata
  | OdStackDefinition !StackDefinition !Bool  -- show_times flag
  | OdStackEvents !StackEventsDisplay
  | OdStackContents !StackContents
  | OdStatusUpdate !StatusUpdate
  | OdCommandResult !CommandResult
  | OdFinalCommandSummary !FinalCommandSummary
  | OdStackList !StackListDisplay
  | OdChangeSetResult !ChangeSetCreationResult
  | OdStackDrift !StackDrift
  | OdError !ErrorInfo
  | OdTokenInfo !TokenInfo
  | OdNewStackEvents ![StackEventWithTiming]
  | OdOperationComplete !OperationCompleteInfo
  | OdInactivityTimeout !InactivityTimeoutInfo
  | OdConfirmationPrompt !ConfirmationRequest
  | OdStackChangeDetails !StackChangeDetails
  | OdStackAbsentInfo !StackAbsentInfo
  | OdCostEstimate !CostEstimate
  | OdStackTemplate !StackTemplate
  | OdApprovalRequestResult !ApprovalRequestResult
  | OdTemplateValidation !TemplateValidation
  | OdApprovalStatus !ApprovalStatus
  | OdTemplateDiff !TemplateDiff
  | OdApprovalResult !ApprovalResult
  | OdPollingStarted !Text       -- spinner message
  | OdRawOutput !Text            -- raw text for non-CFN commands
```

`OutputDispatch` is created once at startup and threaded through all
operations. It auto-detects whether stdout is a TTY and selects the
appropriate renderer:

```haskell
data OutputDispatch
  = DispatchInteractive !InteractiveRenderer
  | DispatchJson !JsonRenderer

mkOutputDispatch :: GlobalOpts -> IO OutputDispatch
renderOutput     :: OutputDispatch -> OutputData -> IO ()
cleanupOutputDispatch :: OutputDispatch -> IO ()
```

**InteractiveRenderer** (`src/Iidy/Output/Renderers/Interactive.hs`,
`Interactive/Sections.hs`, `Interactive/Types.hs`):
Produces colored, formatted terminal output with section headings, tables,
spinners, and status indicators. Uses ansi-terminal for ANSI escape codes.

**JsonRenderer** (`src/Iidy/Output/Renderers/Json.hs`):
Produces machine-readable JSON (one object per line) for piping to jq or
other tools. Each `OutputData` variant has a corresponding conversion.

Supporting modules: `Color.hs` (theme resolution), `Theme.hs` (dark/light/
plain/high-contrast themes), `Spinner.hs` (braille dot animation),
`Terminal.hs` (capability detection including COLUMNS, TTY, NO_COLOR,
FORCE_COLOR), `Status.hs` (status level rendering).

For full details, see [output-architecture.md](output-architecture.md).

## Error System

Directory: `src/Iidy/Yaml/Errors/`

Preprocessing errors carry source location and produce enhanced displays with
caret indicators, contextual help, and fix suggestions. Error codes are
organized into categories:

| Range  | Category               |
|--------|------------------------|
| 1xxx   | YAML syntax & parsing  |
| 2xxx   | Variable & scope       |
| 3xxx   | Import & loading       |
| 4xxx   | Tag parsing & usage    |
| 5xxx   | Type & coercion        |
| 6xxx   | CloudFormation         |
| 7xxx   | Handlebars             |

Key types in `src/Iidy/Yaml/Errors/Enhanced.hs`:

```haskell
data EnhancedPreprocessingError
  = VariableNotFoundError  !VariableNotFoundInfo
  | TypeMismatchError      !TypeMismatchInfo
  | CfnValidationError     !CfnValidationInfo
  | YamlSyntaxError        !YamlSyntaxInfo
  | TagParsingError        !TagParsingInfo
  | LookupQueryError       !LookupQueryInfo
```

Each variant carries an `ErrorId` (the numeric code), a `SourceLocation`
(file, line, column, YAML path), and domain-specific context (available
variables, suggestions, help text, expected/found types). The display module
(`src/Iidy/Yaml/Errors/Display.hs`) renders these with colored output,
source excerpts, caret underlining, and actionable suggestions.

The error conversion pipeline (`Errors/Conversion.hs`, `Conversion/Guidance.hs`,
`Conversion/LineSearch.hs`, `Conversion/Location.hs`) transforms raw internal
errors into enhanced errors by resolving source locations, searching for
relevant lines, and attaching contextual guidance.

The `explain` command accepts error codes and prints detailed documentation
for each.

Top-level exception handling (`src/Iidy/Errors.hs`) catches unhandled
exceptions, formats AWS errors and IO exceptions to match Rust's output
style, and strips GHC backtrace noise.

## Testing Strategy

All tests run offline with no AWS calls.

Key testing approaches:

- **Spec conformance**: Snapshot vectors generated from the PLT Redex spec
  verify the Haskell functions (`oIsTruthy`, `mergeOObjects`, `traversePathO`,
  `astToValueRaw`) produce identical results. Covers three truthiness variants,
  merge key-order preservation, path resolution, escape semantics, and
  map_values binding structure.
- **Snapshot comparison**: Render fixtures are compared against the Rust
  implementation's insta snapshots (`scripts/snapshot-compare.sh` for
  render snapshots, `scripts/error-snapshot-compare.sh` for error
  snapshots).
- **Mock AWS**: CloudFormation operations are tested via dependency injection
  (`pollForCompletionWith` accepts a mock event fetcher).
- **Output pipeline integration**: Test data builders for all `OutputData`
  variants verify that both renderers accept every variant without errors.
- **Property tests**: Handlebars round-trip, YAML parser edge cases, JMESPath
  evaluation, preprocessing algebraic properties.
- **Unit tests**: Individual modules for CLI parser, stack-args loader,
  request builder, template diff, template hash, error classification,
  error IDs, JSON schema, OValue operations, resolver, changeset helpers,
  global config, params client, timing, and more.

For full details, see [testing-guide.md](testing-guide.md).
