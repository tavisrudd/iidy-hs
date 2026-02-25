# PRD Source Code References

Source code file mappings for each requirements document. These references
were removed from the PRDs to keep them implementation-neutral.

## 00-overview.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| Product description    | `docs/getting-started.md`, `docs/command-reference.md`    |
| Exit codes             | `src/Iidy/Main.hs`, `src/Iidy/Cli/Parser.hs`             |
| SIGINT handling        | `app/Main.hs` (installHandler, c_exit 130)                |
| Monad stack            | Plain IO with `CfnContext` passed explicitly, `ExceptT`   |
| YAML engine            | `src/Iidy/Yaml/Engine.hs` (HsYAML event API)             |
| Handlebars             | `src/Iidy/Yaml/Handlebars/` (custom parser/renderer)     |
| JMESPath               | `src/Iidy/Yaml/JMESPath.hs` (~365 LOC custom impl)       |
| JSON Schema            | `src/Iidy/Yaml/CustomResource/JsonSchema.hs` (~170 LOC)  |
| NTP                    | `src/Iidy/Aws/Timing.hs` (~100 LOC SNTP client)          |
| Output                 | `src/Iidy/Output/` (ansi-terminal, not brick)             |
| Key order preservation | OValue type throughout pipeline                           |

## 01-cli-interface.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| Command parser         | `src/Iidy/Cli/Parser.hs` (628 lines)                     |
| Command types          | `src/Iidy/Cli.hs` (Commands, GlobalOpts, AwsOpts, Args)  |
| Custom help renderer   | `src/Iidy/Cli/Help.hs` (shouldShowTopLevelHelp)          |
| Color/theme types      | `src/Iidy/Types.hs` (ColorChoice, OutputMode, Theme)     |
| Output dispatch        | `src/Iidy/Output/Dispatch.hs`                            |
| CLI library            | optparse-applicative with customExecParser                |
| Flag patterns          | `flag True False` for --no-X variants                    |
| Terminal width         | terminal-size library, clamped [60,120], fallback 100     |
| Version                | `Paths_iidy_hs` auto-generated module                    |

## 02-yaml-preprocessing.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| Pipeline orchestration | `src/Iidy/Yaml/Engine.hs` (preprocessYaml, preprocessYaml11) |
| AST types              | `src/Iidy/Yaml/Ast.hs`                                   |
| Tag resolution         | `src/Iidy/Yaml/Resolution/Resolver.hs` (resolveAst)      |
| Variable scope         | `src/Iidy/Yaml/Resolution/Context.hs` (TagContext)        |
| Handlebars engine      | `src/Iidy/Yaml/Handlebars/Engine.hs`                     |
| Handlebars helpers     | `src/Iidy/Yaml/Handlebars/Helpers.hs` (28 helpers)       |
| YAML 1.1 detection     | `src/Iidy/Yaml/Detection.hs`                             |
| Error codes            | `src/Iidy/Yaml/Errors/Ids.hs` (ERR_1001 through 9005)   |
| Phase 1 (imports/defs) | `Engine.hs::loadImportsAndDefs` (foldM over $defs)       |
| Phase 2 (resolution)   | `Engine.hs::process` → `resolveAst` with TagContext      |
| OValue type            | Ordered pairs preserving key insertion order              |

## 03-import-system.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| Import types           | `src/Iidy/Yaml/Imports/Types.hs` (ImportType enum)       |
| Security model         | `Types.hs::parseImportType`, `isLocalOnly`, `isRemoteBase` |
| Cycle detection        | `src/Iidy/Yaml/Imports/Manifest.hs` (ImportStack)        |
| File loader            | `src/Iidy/Yaml/Imports/Loaders/File.hs`                  |
| Env loader             | `src/Iidy/Yaml/Imports/Loaders/Env.hs`                   |
| Git loader             | `src/Iidy/Yaml/Imports/Loaders/Git.hs`                   |
| Random loader          | `src/Iidy/Yaml/Imports/Loaders/Random.hs`                |
| S3 loader              | `src/Iidy/Yaml/Imports/Loaders/S3.hs`                    |
| HTTP loader            | `src/Iidy/Yaml/Imports/Loaders/Http.hs`                  |
| CFN loader             | `src/Iidy/Yaml/Imports/Loaders/Cfn.hs`                   |
| SSM loader             | `src/Iidy/Yaml/Imports/Loaders/Ssm.hs`                   |
| Filehash loaders       | NOT IMPLEMENTED (types defined, no loaders)               |
| Pipeline integration   | `src/Iidy/Yaml/Engine.hs` (loadImportsAndDefs)           |

## 04-custom-resources.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| Parameter definitions  | `src/Iidy/Yaml/CustomResource/Params.hs` (188 LOC)       |
| Expansion pipeline     | `src/Iidy/Yaml/CustomResource/Expansion.hs` (168 LOC)    |
| Reference rewriting    | `src/Iidy/Yaml/CustomResource/RefRewriting.hs` (155 LOC) |
| JSON Schema validator  | `src/Iidy/Yaml/CustomResource/JsonSchema.hs` (192 LOC)   |
| Type matching          | `src/Iidy/Yaml/Resolution/Resolver.hs` (tcCustomTemplateDefs) |
| Key types              | `ParamDef`, `TemplateInfo`, `ExpansionResult`             |
| AWS pseudo-refs        | shouldRewrite excludes `AWS::*` prefixed refs             |

## 05-cfn-operations.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| Create stack           | `src/Iidy/Cfn/Operations/CreateStack.hs`                 |
| Update stack           | `src/Iidy/Cfn/Operations/UpdateStack.hs`                 |
| Delete stack           | `src/Iidy/Cfn/Operations/DeleteStack.hs`                 |
| Create or update       | `src/Iidy/Cfn/Operations/CreateOrUpdate.hs`              |
| Changesets             | `src/Iidy/Cfn/Operations/Changeset.hs`                   |
| Describe stack         | `src/Iidy/Cfn/Operations/DescribeStack.hs`               |
| Watch stack            | `src/Iidy/Cfn/Operations/WatchStack.hs`                  |
| Drift detection        | `src/Iidy/Cfn/Operations/DescribeStackDrift.hs`          |
| Estimate cost          | `src/Iidy/Cfn/Operations/EstimateCost.hs`                |
| Lint template          | `src/Iidy/Cfn/Operations/LintTemplate.hs`                |
| List stacks            | `src/Iidy/Cfn/Operations/ListStacks.hs`                  |
| Get template           | `src/Iidy/Cfn/Operations/GetStackTemplate.hs`            |
| Polling                | `src/Iidy/Cfn/StackOperations.hs` (pollForCompletionWith)|
| Confirmation           | `src/Iidy/Confirm.hs` (requestConfirmation)              |
| Command metadata       | `src/Iidy/Cfn/CommandMetadata.hs`                        |
| Stack definition       | `src/Iidy/Cfn/Operations/DescribeStack.hs` (convertStack)|
| Stack contents         | `src/Iidy/Cfn/StackOperations.hs` (collectStackContents) |
| Token derivation       | `src/Iidy/Aws/ClientReqToken.hs` (ctxDeriveToken)        |
| Random names           | generateDashedName in CreateOrUpdate.hs                   |

## 06-output-system.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| OutputData types       | `src/Iidy/Output/Types.hs` (26 constructors, ~457 LOC)   |
| Interactive renderer   | `src/Iidy/Output/Renderers/Interactive.hs` (~1047 LOC)   |
| JSON renderer          | `src/Iidy/Output/Renderers/Json.hs` (~521 LOC)           |
| Dispatch/wiring        | `src/Iidy/Output/Manager.hs` (~127 LOC)                  |
| Color/themes           | `src/Iidy/Output/Color.hs` (~236 LOC)                    |
| Terminal detection     | `src/Iidy/Output/Terminal.hs` (~47 LOC)                  |
| Theme enum             | `src/Iidy/Output/Theme.hs` (~39 LOC)                     |
| Spinner                | `src/Iidy/Output/Spinner.hs` (~117 LOC)                  |
| Status categorization  | `src/Iidy/Output/Status.hs` (~46 LOC)                    |
| Key types              | InteractiveRenderer, JsonRenderer, IidyTheme, TerminalCapabilities |
| Key functions          | mkOutputDispatch, renderOutput, formatSectionHeading      |

## 07-error-handling.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| Error IDs              | `src/Iidy/Yaml/Errors/Ids.hs` (50 ErrorId constructors)  |
| Enhanced display       | `src/Iidy/Yaml/Errors/Display.hs` (formatError)          |
| Error types            | `src/Iidy/Yaml/Errors/Enhanced.hs` (6 enhanced variants) |
| Position tracking      | `src/Iidy/Yaml/Errors/Location.hs`                       |
| Error conversion       | `src/Iidy/Yaml/Errors/Conversion.hs` (~1424 LOC)         |
| Color detection        | `Display.hs::detectErrorColors` (checks stderr TTY)       |
| Explain command        | `src/Iidy/Explain.hs`                                    |
| Error color tests      | `test/Test/ErrorColorTest.hs` (7 tests)                  |
| Error fixture tests    | `test/Test/ErrorFixtureTest.hs` (49 fixtures)            |

## 08-aws-integration.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| AWS config setup       | `src/Iidy/Aws/Config.hs` (218 LOC, createAwsEnv)        |
| Credential detection   | `Config.hs::detectCredentialSources`                      |
| Credential source types| `src/Iidy/Aws/CredentialSource.hs` (67 LOC)              |
| STS integration        | `src/Iidy/Aws/Sts.hs` (30 LOC, getCallerIdentity)       |
| NTP timing             | `src/Iidy/Aws/Timing.hs` (130 LOC)                       |
| Stack args loading     | `src/Iidy/Cfn/StackArgsLoader.hs` (270 LOC)             |
| Command metadata       | `src/Iidy/Cfn/CommandMetadata.hs` (~150 LOC)             |
| Profile handling       | setEnv "AWS_PROFILE" before Amazonka.discover             |
| Assume role            | STS.fromAssumedRole with auto-refresh                     |
| Region resolution      | Config.hs::resolveRegion                                  |
| Auth chain analysis    | `notes/aws-auth-chain-analysis.md`                       |

## 09-ssm-params.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| Param operations       | `src/Iidy/Ssm/Client.hs` (paramSet, paramGet, etc.)     |
| Param review           | `src/Iidy/Ssm/Review.hs` (applyPendingChange)           |
| CLI types              | `src/Iidy/Cli.hs` (ParamSetArgs, ParamGetArgs, etc.)    |
| Parser                 | `src/Iidy/Cli/Parser.hs` (param subcommands)            |
| AWS SDK                | amazonka-ssm (PutParameter, GetParameter, etc.)          |

## 10-template-approval.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| Approval operations    | `src/Iidy/Cfn/Operations/TemplateApproval.hs`            |
| S3 operations          | amazonka-s3 (PutObject, GetObject, HeadObject, DeleteObject) |
| Hash generation        | SHA256 of processed template body                         |
| Diff generation        | Simple line-based set difference                          |
| Output types           | OdApprovalRequestResult, OdApprovalStatus, OdTemplateDiff, OdApprovalResult |

## 11-utilities.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| Render command         | `src/Iidy/Render.hs`                                     |
| Explain command        | `src/Iidy/Explain.hs`                                    |
| Demo command           | `src/Iidy/Demo.hs`                                       |
| Init command           | `src/Iidy/InitStackArgs.hs`                              |
| Get-import command     | `src/Iidy/GetImport.hs`                                  |
| Convert command        | `src/Iidy/Cfn/Operations/ConvertStack.hs`                |
| Completion             | optparse-applicative CompletionInvoked in Parser.hs      |
| Lint template          | `src/Iidy/Cfn/Operations/LintTemplate.hs`                |
| Estimate cost          | `src/Iidy/Cfn/Operations/EstimateCost.hs`                |

## 12-cross-cutting.md

| Topic                  | Source Files                                              |
|------------------------|-----------------------------------------------------------|
| YAML version detection | `src/Iidy/Yaml/Detection.hs`                             |
| Terminal capabilities  | `src/Iidy/Output/Terminal.hs`                             |
| NTP sync               | `src/Iidy/Aws/Timing.hs`                                 |
| Idempotency tokens     | `src/Iidy/Aws/ClientReqToken.hs`                         |
| Signal handling        | `app/Main.hs` (POSIX installHandler)                     |
| Confirmation prompts   | `src/Iidy/Confirm.hs`                                    |
| Color themes           | `src/Iidy/Output/Color.hs`, `Theme.hs`                   |
