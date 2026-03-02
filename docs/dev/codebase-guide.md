# iidy-hs Codebase Guide

Module navigation reference for the iidy-hs Haskell project (86 modules).

## Quick Start

```
cabal build          # compile (runs inside nix devshell)
cabal test           # run all 851 tests
cabal run iidy-hs    # run the binary
```

Entry point: `app/Main.hs` -- parses CLI, dispatches to command handlers.

## Project Structure

```
iidy-hs/
  app/Main.hs              -- Entry point: CLI parse + command dispatch
  src/Iidy/                 -- Library source (86 modules)
  test/Main.hs              -- Test entry point; suites in test/Test/ (~7400 LOC, 851 tests)
  test-fixtures/             -- Snapshot data and example templates
    example-templates/       -- YAML templates for render/preprocess tests
    expected-outputs/        -- Golden output snapshots
  docs/                      -- Developer documentation
  notes/                     -- Phase research, session logs, analysis
  scripts/                   -- Snapshot comparison and CI helpers
  iidy-hs.cabal              -- Package definition
  flake.nix                  -- Nix build and devshell
```

## Source Modules by Layer

### CLI Layer

```
src/Iidy/
  Cli.hs                    -- Command enum, GlobalOpts, StackOpts
  Cli/
    Parser.hs               -- optparse-applicative parser construction
```

### YAML Preprocessing Layer

```
src/Iidy/Yaml/
  Parser.hs                 -- HsYAML event-based parsing with position tracking
  Ast.hs                    -- YamlAst node definitions
  Location.hs               -- Error position tracking (line/column)
  PathTracker.hs            -- Efficient AST path tracking during traversal
  Detection.hs              -- YAML 1.1 vs 1.2 auto-detection
  Engine.hs                 -- Two-phase preprocessing pipeline entry point
  OValue.hs                 -- Ordered value type (key-order preservation)
  Emitter.hs                -- Custom YAML emitter (preserves key sort order)
  JMESPath.hs               -- Custom JMESPath query implementation (~600 LOC)
  Handlebars/
    Engine.hs               -- Custom handlebars parser/renderer
    Helpers.hs              -- 28 handlebars helper functions
  Resolution/
    Resolver.hs             -- Tag resolver for 21+ custom tags
    Context.hs              -- Resolution context (vars, imports, config)
  Imports/
    Types.hs                -- Import manifest definitions
    Manifest.hs             -- Import loader interface
    Loaders/
      File.hs               -- Local filesystem imports
      Env.hs                -- Environment variable imports
      S3.hs                 -- S3 object imports
      Http.hs               -- HTTP/HTTPS imports
      Cfn.hs                -- CloudFormation stack/export imports
      Ssm.hs                -- SSM Parameter Store imports
      Git.hs                -- Git repository imports
      Random.hs             -- Random value generation
  CustomResources/
    Params.hs               -- Parameter definition parsing
    Expansion.hs            -- Template expansion with $params
    RefRewriting.hs         -- Reference rewriting in expanded templates
    JsonSchema.hs           -- Minimal JSON Schema Draft 7 validator (~170 LOC)
  Errors/
    Ids.hs                  -- 50+ error IDs with explanations
    Enhanced.hs             -- Enhanced error display with context
    Display.hs              -- Custom error formatting with line/column
    Conversion.hs           -- Error conversion from AWS/JSON Schema errors
```

### CloudFormation Layer

```
src/Iidy/Cfn/
  Types.hs                  -- StackArgs, operation enums, change types
  Context.hs                -- CfnContext (AWS clients + config)
  Constants.hs              -- Poll intervals, timeouts, event counts
  Status.hs                 -- Stack/resource status categorization
  TemplateHash.hs           -- Template hashing for change detection
  TemplateLoader.hs         -- Load + preprocess templates
  StackArgsLoader.hs        -- Load stack-args.yaml with env overrides
  RequestBuilder.hs         -- CloudFormation API request construction
  StackOperations.hs        -- Polling, event fetching, status checking
  CommandMetadata.hs        -- Construct metadata + final command summaries
  Operations/
    CreateStack.hs          -- create-stack command
    UpdateStack.hs          -- update-stack command (direct + changeset)
    CreateOrUpdate.hs       -- create-or-update command (5 code paths)
    DeleteStack.hs          -- delete-stack command with confirmation
    DescribeStack.hs        -- describe-stack command
    ListStacks.hs           -- list-stacks command
    WatchStack.hs           -- watch-stack command with inactivity timeout
    GetStackTemplate.hs     -- get-stack-template command
    DescribeStackDrift.hs   -- describe-stack-drift with paginated results
    EstimateCost.hs         -- estimate-cost command
    LintTemplate.hs         -- lint-template command
    TemplateApproval.hs     -- template-approval command
    Changeset.hs            -- Shared changeset operations + helpers
    ConvertStack.hs         -- convert-stack-to-iidy command
```

### AWS Layer

```
src/Iidy/Aws/
  Config.hs                 -- AWS SDK configuration + region resolution
  CredentialSource.hs       -- Credential source detection
  ClientReqToken.hs         -- Idempotency token management
  Sts.hs                    -- STS operations (getCallerIdentity)
  Timing.hs                 -- NTP time sync + time providers
```

### Output Layer

```
src/Iidy/Output/
  Types.hs                  -- 26 OutputData variants
  Renderer.hs               -- Renderer trait + OutputMode enum
  Manager.hs                -- OutputDispatch routing
  Color.hs                  -- ANSI color codes + themes
  Theme.hs                  -- Light/Dark/HighContrast schemes
  Terminal.hs               -- Terminal capabilities detection
  Status.hs                 -- Stack/resource status styling helpers
  Spinner.hs                -- Progress spinner with timing display
  Renderers/
    Interactive.hs          -- ANSI terminal output
    Json.hs                 -- JSON structured output
```

### Supporting Commands

```
src/Iidy/
  Render.hs                 -- render command
  Explain.hs                -- Error code explanation
  Demo.hs                   -- Demo script execution
  GetImport.hs              -- Retrieve import values
  InitStackArgs.hs          -- Scaffold new stack-args project
  Types.hs                  -- Basic shared type definitions
```

### SSM Parameters

```
src/Iidy/Params/
  Client.hs                 -- SSM parameter CRUD operations
  Review.hs                 -- Review pending parameter changes
```

## Test Structure

Tests are split across multiple modules:

```
test/Main.hs               -- Entry point: registers test groups (tasty framework)
test/Test/                 -- 851 tests across ~7400 LOC of test modules
test-fixtures/
  example-templates/        -- YAML input fixtures
  expected-outputs/         -- Golden output snapshots
```

Test categories: unit tests for each layer, snapshot comparison against Rust
oracle outputs, property tests for parsers and emitters, integration tests
for the output pipeline (renderer pass-through, output sequencing).

Scripts for cross-implementation snapshot comparison:

```
scripts/
  snapshot-compare.sh       -- Compare render fixtures vs Rust snapshots
  error-snapshot-compare.sh -- Compare error fixtures vs Rust snapshots
```

## Key Entry Points

Reading order for understanding the codebase:

1. `app/Main.hs` -- CLI dispatch; shows how commands map to handlers
2. `src/Iidy/Cli/Parser.hs` -- All 22 commands and their option parsing
3. `src/Iidy/Cfn/Context.hs` -- CfnContext threading through all operations
4. `src/Iidy/Yaml/Engine.hs` -- Preprocessing pipeline (import, resolve, emit)
5. `src/Iidy/Output/Manager.hs` -- OutputDispatch wiring renderers to commands
6. `src/Iidy/Output/Types.hs` -- The 26 OutputData variants that flow through the system

Data flow for a typical stack operation:

```
Main.hs
  -> Cli/Parser.hs          (parse CLI args)
  -> Cfn/StackArgsLoader.hs  (load stack-args.yaml)
  -> Yaml/Engine.hs          (preprocess template)
  -> Cfn/RequestBuilder.hs   (build API request)
  -> Cfn/Operations/*.hs     (execute operation)
  -> Output/Manager.hs       (dispatch OutputData to renderer)
  -> Output/Renderers/*.hs   (format for terminal or JSON)
```
