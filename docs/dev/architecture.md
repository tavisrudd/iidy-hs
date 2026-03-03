# iidy-hs Architecture

## Overview

iidy-hs is a Haskell port of [iidy](https://github.com/unbounce/iidy), a
CloudFormation preprocessor and deployer. It reads YAML "stack-args" files
that describe a CloudFormation deployment (template, parameters, tags, etc.),
preprocesses them through a custom YAML engine with imports, variable
resolution, handlebars interpolation, and custom tags, then drives
CloudFormation operations through the AWS API.

The codebase is ~17,800 LOC of Haskell across 89 modules, using GHC 9.10 and
amazonka 2.0. It implements 22 CLI commands covering the full lifecycle:
stack CRUD, changesets, drift detection, SSM parameter management, template
approval workflows, and offline utilities (render, lint, explain, demo).

The preprocessing language has a [PLT Redex formal specification](../../spec/README.md)
that serves as the executable ground truth for semantics. A snapshot-based
conformance test suite verifies the Haskell implementation agrees with the
spec on key drift-point behaviors (truthiness, merge ordering, path resolution,
escape, map_values binding).

Several subsystems are custom implementations rather than library wrappers:
JMESPath query evaluation (~365 LOC), Handlebars template engine (~755 LOC),
and JSON Schema Draft 7 validation. No suitable Haskell libraries existed
for these with the specific semantics iidy requires.

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

## CLI Parsing

Entry point: `app/Main.hs` dispatches parsed commands.
Parser: `src/Iidy/Cli/Parser.hs` defines the optparse-applicative parser.
Types: `src/Iidy/Cli.hs` defines all command and option types.

The `Commands` sum type has 22 constructors, one per command:

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
  | CmdCompletion !(Maybe Text)
  | CmdExplain ![Text]
```

`GlobalOpts` carries cross-cutting flags (environment, color, theme, output
mode, debug). `AwsOpts` carries AWS-specific CLI flags (region, profile,
assume-role-arn, client-request-token) which are normalized and merged with
argsfile-level settings during stack-args loading.

## Stack-Args Loading

File: `src/Iidy/Cfn/StackArgsLoader.hs`

The stack-args loader is the bridge between the CLI and CloudFormation
operations. It takes a YAML argsfile path and produces a `LoadedStackArgs`:

```haskell
loadStackArgs
  :: FilePath        -- argsfile path
  -> Text            -- environment name
  -> CfnOperation    -- operation being performed
  -> AwsSettings     -- CLI-provided AWS settings
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

Files: `src/Iidy/Yaml/Imports/` (3 modules + loaders), `src/Iidy/Yaml/Engine.hs`

Phase 1 walks the AST looking for `$imports` and `$defs` directives. Imports
are loaded via a pluggable `LoadImportFn` (file, HTTP, S3), and their results
are merged into the resolution context. Circular imports are detected and
rejected.

### Phase 2: Tag Resolution and Handlebars

Files: `src/Iidy/Yaml/Resolution/Resolver.hs`, `src/Iidy/Yaml/Handlebars/Engine.hs`

Phase 2 resolves 21 custom YAML tags and interpolates handlebars expressions.
The resolver walks the AST depth-first, processing each tagged node:

| Tag Category     | Tags                                                           |
|------------------|----------------------------------------------------------------|
| Variable access  | `!$` (lookup), `!$escape`                                      |
| Data loading     | `!$include`, `!$parseYaml`, `!$parseJson`                      |
| String ops       | `!$concat`, `!$join`, `!$split`, `!$replace`, `!$string`       |
| Conditionals     | `!$if`, `!$not`, `!$eq`                                        |
| Collections      | `!$merge`, `!$mergeMap`, `!$fromPairs`, `!$groupBy`            |
| Queries          | `!$jmespath`, `!$jsonpath`                                     |
| Encoding         | `!$toJsonString`, `!$toYamlString`                             |
| CloudFormation   | `!$envValues`, `!$filehash`                                    |

Handlebars interpolation uses a custom engine with 28 helpers (arithmetic,
string manipulation, conditionals, encoding, file operations).

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
`Value` type. The critical difference is `OObject`: it stores key-value pairs
as an association list, preserving insertion order. This is essential for
output fidelity -- CloudFormation templates must emit keys in a deterministic
order matching the source file, and the custom YAML emitter
(`src/Iidy/Yaml/Emitter.hs`) relies on this ordering.

Conversion between `OValue` and `Value` is provided by `toValue`/`fromValue`,
but note that `toValue` loses key ordering (aeson objects are hash maps).

### JMESPath

File: `src/Iidy/Yaml/JMESPath.hs` (~365 LOC)

Custom JMESPath implementation supporting the query operations iidy uses:
field access, nested/index expressions, projections, filters, multi-select
lists and hashes, pipes, and built-in functions (length, keys, values, sort,
join, etc.). Used by `!$jmespath` tags, `--query` CLI flags, and list-stacks
filtering.

### Custom Resources and JSON Schema

Files: `src/Iidy/Yaml/CustomResources/` (4 modules)

CloudFormation custom resources (`Custom::*` types) are expanded into their
`AWS::CloudFormation::CustomResource` equivalents. The expansion pipeline
rewrites resource types, normalizes properties, and handles Ref/GetAtt
rewriting. A custom JSON Schema Draft 7 validator
(`src/Iidy/Yaml/CustomResources/JsonSchema.hs`) validates resource schemas.

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
  }
```

The monad stack is plain `IO`. `CfnContext` is passed explicitly to every
operation function rather than wrapped in a `ReaderT`. This was a deliberate
design choice: the Rust source passes context explicitly, and the additional
type machinery of a transformer stack provided no benefit for a CLI tool with
a linear execution path.

The `TimeProvider` abstraction supports both `systemTimeProvider` (uses
`getCurrentTime`) and `reliableTimeProvider` (NTP-corrected via custom SNTP
client). NTP correction is important in CI environments where system clocks
may drift.

### Operation Modules

Each CloudFormation command has a dedicated module under
`src/Iidy/Cfn/Operations/`:

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

### Polling and Event Streaming

File: `src/Iidy/Cfn/StackOperations.hs`

Write operations (create, update, delete) poll CloudFormation until the stack
reaches a terminal state. `pollForCompletion` drives the loop:

```haskell
pollForCompletion :: CfnContext -> PollConfig -> (OutputData -> IO ()) -> IO Text
```

It fetches events every N seconds, emits new events via the `OutputData`
callback (as `OdNewStackEvents`), detects inactivity timeouts, and returns the
final stack status. A dependency-injected variant `pollForCompletionWith`
accepts a custom event-fetcher for testing.

The spinner runs on a background `forkIO` thread, ticking every 80ms.
This is the only use of concurrency in the codebase.

## SSM Parameter Store

Files: `src/Iidy/Params/Client.hs`, `src/Iidy/Params/Review.hs`

Four SSM operations: `paramGet`, `paramSet`, `paramGetByPath`,
`paramGetHistory`. The review module (`paramReview`) provides an interactive
diff of pending vs. current parameter values at a path, used in the
approval workflow.

## Output System

Directory: `src/Iidy/Output/`

The output system is data-driven. All operation results flow through a single
`OutputData` sum type (26 variants) rather than performing direct I/O:

```haskell
-- Operations emit structured data:
emit :: (OutputData -> IO ()) -> OutputData -> IO ()

-- The dispatch routes to the active renderer:
mkOutputDispatch :: GlobalOpts -> IO (OutputData -> IO ())
```

`OutputDispatch` is created once at startup and threaded through all
operations. It auto-detects whether stdout is a TTY and selects the
appropriate renderer.

**InteractiveRenderer** (`src/Iidy/Output/Renderers/Interactive.hs`):
Produces colored, formatted terminal output with section headings, tables,
spinners, and status indicators. Uses ansi-terminal for ANSI escape codes.

**JsonRenderer** (`src/Iidy/Output/Renderers/Json.hs`):
Produces machine-readable JSON (one object per line) for piping to jq or
other tools. Each `OutputData` variant has a corresponding `*ToValue`
conversion function.

Supporting modules: `Color.hs` (theme resolution), `Theme.hs` (dark/light/
plain themes), `Spinner.hs` (braille dot animation), `Terminal.hs` (capability
detection), `Status.hs` (status level rendering).

For full details, see [output-architecture.md](output-architecture.md).

## Error System

Directory: `src/Iidy/Yaml/Errors/`

Preprocessing errors carry source location and produce enhanced displays with
caret indicators, contextual help, and fix suggestions. There are 50 error
codes organized into categories:

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
  = EpeVariableNotFound  !VariableNotFoundInfo
  | EpeTypeMismatch      !TypeMismatchInfo
  | EpeCfnValidation     !CfnValidationInfo
  | EpeYamlSyntax        !YamlSyntaxInfo
  | EpeTagParsing        !TagParsingInfo
  | EpeLookupQuery       !LookupQueryInfo
```

Each variant carries an `ErrorId` (the numeric code), a `SourceLocation`
(file, line, column), and domain-specific context. The display module
(`src/Iidy/Yaml/Errors/Display.hs`) renders these with colored output,
source excerpts, caret underlining, and actionable suggestions.

The `explain` command accepts error codes and prints detailed documentation
for each.

## Testing Strategy

All tests run offline with no AWS calls.

Key testing approaches:

- **Spec conformance**: Snapshot vectors generated from the PLT Redex spec
  verify the Haskell functions (`oIsTruthy`, `mergeOObjects`, `traversePathO`,
  `astToValueRaw`) produce identical results. Covers three truthiness variants,
  merge key-order preservation, path resolution, escape semantics, and
  map_values binding structure.
- **Snapshot comparison**: Render fixtures are compared against the Rust
  implementation's insta snapshots (`scripts/snapshot-compare.sh` for 37
  render snapshots, `scripts/error-snapshot-compare.sh` for 49 error
  snapshots).
- **Mock AWS**: CloudFormation operations are tested via dependency injection
  (`pollForCompletionWith` accepts a mock event fetcher).
- **Output pipeline integration**: Test data builders for all 26 `OutputData`
  variants verify that both renderers accept every variant without errors.
- **Property tests**: Handlebars round-trip, YAML parser edge cases, JMESPath
  evaluation, preprocessing algebraic properties.

For full details, see [testing-guide.md](testing-guide.md).
