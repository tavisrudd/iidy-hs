# iidy-hs Workplan

**Source**: 16,615 LOC Rust across 96 modules
**Target**: ~11,000-13,000 LOC Haskell (estimated 65-75% of Rust LOC)
**Approach**: Bottom-up, dependency-ordered porting with stage gates
**Status**: APPROVED (self-reviewed with 3 parallel risk analyses)
**Reviews**: See `notes/workplan-risk-review.md`, `notes/workplan-agent-resilience.md`, `notes/workplan-operational-review.md`

## Critical Operational Notes (from reviews)

1. **Git signing**: Run `git config --local commit.gpgsign false` in iidy-hs before any commits. Global config has gpgsign=true which will hang on YubiKey.
2. **Commits**: Use `--no-gpg-sign` flag (or rely on local config above).
3. **AWS credentials**: ALL testing is offline with mock fixtures. No real AWS calls during development. Human will test with real AWS access at the end only.
4. **First-build de-risk**: Create skeleton cabal file with ALL deps, run `cabal build --dry-run` first to validate dependency resolution before writing any code.
5. **amazonka in nixpkgs**: Pre-built (2.0-unstable-2025-04-16), all 7 sub-packages available. No OOM risk from compiling amazonka.
6. **No brick needed**: Interactive renderer is ANSI output, not a TUI. Use ansi-terminal only.
7. **Build limits**: `cabal jobs: 4`, GHC `-O0` for dev builds, `-split-sections` for linking.
8. **Token budget**: 5hr/week Claude Max. Target 2-3 sessions/week. ~6-8 weeks total at this rate.
9. **No sudo, no home-manager switch**: All deps through Nix flake only.
10. **Human notifications**: `curl -s -H "Priority: high" -H "Tags: wrench" -d "MESSAGE" ntfy.sh/tavis-iidy-port-2026` — use ONLY for true blockers (stage gate fails 3x with no path forward, ecosystem gap with no workaround). No human intervention expected until final review.
11. **Rust binary as oracle**: The Rust binary at `~/src/iidy/target/debug/iidy` is available for any offline reference — `--help` structure, `render` output, `explain` codes, error message formatting, YAML preprocessing, etc. Use it freely to diff against the Haskell port for any command that doesn't require AWS credentials. Also copy 98 `.snap` files from `~/src/iidy/tests/snapshots/` into iidy-hs during Phase 1.
12. **Fully autonomous**: No human checkpoints between now and final review. Ship it.
13. **Safety**: No destructive operations (rm -rf, git reset --hard, force push). No modifications to files outside `~/src/iidy-hs/`. No writing credentials, secrets, or API keys to disk. No network calls except Hackage/nixpkgs downloads, ntfy notifications, and web searches for Haskell library docs/examples. Read-only access to `~/src/iidy/` (the Rust source).

## Module Porting Order

Based on the dependency graph, modules are ported bottom-up. Each chunk produces compilable, testable code.

```
Layer 0 (no deps):     Core types, error types, constants
Layer 1 (types only):  AST nodes, position tracking, path tracker
Layer 2 (core logic):  YAML parser, detection, emitter
Layer 3 (resolution):  Resolution context, tag resolver, handlebars, JMESPath
Layer 4 (imports):     Import system + loaders (file, env, random first; then http, s3, ssm, cfn, git)
Layer 5 (engine):      Two-phase engine, custom resources
Layer 6 (output):      Output data types, renderer trait, color/theme/terminal/status/spinner
Layer 7 (renderers):   Interactive renderer, JSON renderer, plain renderer
Layer 8 (AWS):         AWS config, credentials, timing, client request tokens
Layer 9 (CFN core):    CfnContext, stack_args, request_builder, template_loader, stack_operations
Layer 10 (CFN ops):    Individual operations (create, update, delete, describe, watch, etc.)
Layer 11 (params):     SSM parameter operations
Layer 12 (CLI):        optparse-applicative definitions, main entry point
Layer 13 (ancillary):  Demo, explain, render command, template approval, convert-stack
```

## Phases & Chunks

### Phase 1: Project Skeleton + Core Types
**Gate**: `cabal build` succeeds, all type modules compile

| Chunk | Source Modules | Est. LOC | Delegation |
|-------|---------------|----------|------------|
| 1.1 | Nix flake + cabal project setup | ~100 | Sonnet |
| 1.2 | Core types: Position, PathTracker, ErrorId, error types | ~300 | Sonnet |
| 1.3 | AST nodes (ScalarNode, SequenceNode, MappingNode) | ~200 | Sonnet |
| 1.4 | Output data types (OutputData enum + all structs) | ~350 | Sonnet |
| 1.5 | CLI types (Commands enum, GlobalOpts, AwsOpts, all arg structs) | ~400 | Sonnet |
| 1.6 | AWS types (AwsSettings, CredentialSource, TokenInfo, CfnOperation) | ~150 | Sonnet |
| 1.7 | CloudFormation status constants + categorization | ~100 | Sonnet |

**Total Phase 1**: ~1,600 LOC
**Session estimate**: 1 session

### Phase 2: YAML Preprocessing Engine
**Gate**: `render` command works on test fixtures, snapshot tests pass for YAML output

| Chunk | Source Modules | Est. LOC | Delegation |
|-------|---------------|----------|------------|
| 2.1 | YAML parsing: HsYAML-based parser with position tracking | ~800 | Opus |
| 2.2 | YAML detection (spec version, CF/K8s detection) | ~150 | Sonnet |
| 2.3 | Resolution context (TagContext, EnvValues, VariableSource, metadata) | ~500 | Opus |
| 2.4 | Tag resolver (all custom tags: !$, !cfn, !sub, !join, etc.) | ~1,200 | Opus |
| 2.5 | Handlebars/Mustache engine + helpers (case, encoding, string manip) | ~400 | Sonnet after Opus designs interface |
| 2.6 | JMESPath evaluator (port jamespath-hs or minimal impl) | ~600 | Opus |
| 2.7 | Import system: trait + manifest + security model | ~250 | Opus |
| 2.8 | Import loaders: file, env, random (no AWS deps) | ~300 | Sonnet |
| 2.9 | Custom resources: params, expansion, ref_rewriting | ~500 | Sonnet |
| 2.10 | YAML emitter (iidy-js compatible output) | ~350 | Opus |
| 2.11 | Two-phase engine orchestration | ~500 | Opus |
| 2.12 | Error display with source context (enhanced errors) | ~500 | Opus |

**Total Phase 2**: ~6,050 LOC
**Session estimate**: 4-5 sessions

### Phase 3: Output System
**Gate**: Interactive, JSON, and plain renderers produce correct output for all OutputData variants; pixel-perfect snapshot tests pass

| Chunk | Source Modules | Est. LOC | Delegation |
|-------|---------------|----------|------------|
| 3.1 | OutputRenderer typeclass + OutputMode + DynamicOutputManager | ~150 | Opus |
| 3.2 | Color system (ColorContext, ColorChoice, Theme, ANSI output) | ~300 | Sonnet |
| 3.3 | Terminal capabilities detection | ~100 | Sonnet |
| 3.4 | Spinner (indicatif equivalent using brick or custom) | ~80 | Sonnet |
| 3.5 | Interactive renderer (2438 LOC Rust -> ~1,500 LOC Haskell) | ~1,500 | Opus |
| 3.6 | JSON renderer | ~300 | Sonnet |
| 3.7 | AWS type conversion (AWS SDK types -> OutputData) | ~500 | Sonnet after Opus designs patterns |

**Total Phase 3**: ~2,930 LOC
**Session estimate**: 2-3 sessions

### Phase 4: AWS + CloudFormation Integration
**Gate**: `describe-stack`, `list-stacks`, `create-stack`, `update-stack`, `delete-stack` work against real AWS (or localstack)

| Chunk | Source Modules | Est. LOC | Delegation |
|-------|---------------|----------|------------|
| 4.1 | amazonka client setup + credential detection + config loading | ~500 | Opus |
| 4.2 | Stack args loader (preprocess stack-args.yaml -> StackArgs) | ~400 | Sonnet |
| 4.3 | Request builder (parameters, tags, capabilities -> API request) | ~350 | Sonnet |
| 4.4 | Template loader (preprocess + validate + upload to S3) | ~250 | Sonnet |
| 4.5 | Stack operations core (poll status, get events, filter) | ~250 | Sonnet |
| 4.6 | CfnContext + command handler macros (as Haskell functions) | ~300 | Opus |
| 4.7 | describe-stack + list-stacks (read-only, good first test) | ~200 | Sonnet |
| 4.8 | create-stack + update-stack + create-or-update | ~350 | Sonnet |
| 4.9 | delete-stack (with confirmation prompt) | ~150 | Sonnet |
| 4.10 | watch-stack (continuous polling with event streaming) | ~250 | Opus |
| 4.11 | Changeset operations (create, describe, execute) | ~400 | Sonnet |
| 4.12 | Import loaders requiring AWS: s3, ssm, cfn | ~600 | Sonnet |
| 4.13 | Template approval (request + review) | ~200 | Sonnet |
| 4.14 | Drift detection | ~100 | Sonnet |
| 4.15 | get-stack-template, estimate-cost, lint-template | ~150 | Sonnet |

**Total Phase 4**: ~4,450 LOC
**Session estimate**: 3-4 sessions

### Phase 5: CLI + Remaining Commands
**Gate**: All CLI commands parse correctly; `iidy-hs --help` matches Rust version

| Chunk | Source Modules | Est. LOC | Delegation |
|-------|---------------|----------|------------|
| 5.1 | optparse-applicative CLI definition (all commands, flags) | ~500 | Sonnet |
| 5.2 | Main entry point + command router | ~200 | Sonnet |
| 5.3 | Render command | ~100 | Sonnet |
| 5.4 | Get-import command | ~100 | Sonnet |
| 5.5 | Explain command + error code database | ~100 | Sonnet |
| 5.6 | SSM parameter commands (get, set, get-by-path, history, review) | ~250 | Sonnet |
| 5.7 | Convert-stack-to-iidy (reverse engineering) | ~500 | Sonnet |
| 5.8 | Init-stack-args (scaffolding) | ~100 | Sonnet |
| 5.9 | Demo command (PTY, masking, playback) | ~350 | Opus |
| 5.10 | Import loaders: http, git | ~250 | Sonnet |
| 5.11 | Shell completion generation | ~50 | Sonnet |

**Total Phase 5**: ~2,500 LOC
**Session estimate**: 2-3 sessions

### Phase 6: Integration Testing + Polish
**Gate**: All snapshot tests pass (byte-identical output); all commands work end-to-end

| Chunk | Source Modules | Est. LOC | Delegation |
|-------|---------------|----------|------------|
| 6.1 | Test infrastructure: golden-file framework, test utilities | ~200 | Opus |
| 6.2 | YAML preprocessing snapshot tests (port from Rust snapshots) | ~300 | Sonnet |
| 6.3 | Output renderer snapshot tests (pixel-perfect) | ~200 | Sonnet |
| 6.4 | Error display snapshot tests | ~150 | Sonnet |
| 6.5 | Property-based tests (QuickCheck/hedgehog for parser) | ~200 | Sonnet |
| 6.6 | Integration tests (template loading, full workflow) | ~300 | Sonnet |
| 6.7 | Performance profiling + optimization | ~100 | Opus |
| 6.8 | Final snapshot comparison: Rust output vs Haskell output | -- | Opus |

**Total Phase 6**: ~1,450 LOC (tests)
**Session estimate**: 2-3 sessions

## Stage Gates

### Gate 1 (after Phase 1): Types Compile
- [x] `nix develop` enters Haskell shell with GHC + cabal
- [x] `cabal build` succeeds with all type modules
- [x] No warnings with `-Wall`

### Gate 2 (after Phase 2): YAML Engine Works
- [x] `render` command processes all 6 test fixtures
- [x] Snapshot output matches Rust's insta snapshots for example templates
- [x] Error example snapshots match (enhanced error formatting)
- [x] Handlebars interpolation passes equivalence tests
- [ ] Property tests pass for parser (deferred — unit tests cover core paths)

### Gate 3 (after Phase 3): Output Renders Correctly
- [x] Interactive renderer pixel-perfect test passes (130-char width)
- [x] JSON renderer produces valid JSONL
- [x] Plain renderer strips ANSI codes
- [x] Color themes (dark/light/high-contrast) render correctly
- [x] NO_COLOR environment variable respected

### Gate 4 (after Phase 4): CloudFormation Compiles + Unit Tests
- [x] All amazonka call sites compile and type-check
- [ ] Mock/fixture-based unit tests pass for request building, response parsing, event filtering
- [ ] `watch-stack` streams mock events with spinner
- [ ] `delete-stack` prompts for confirmation (no real AWS)
- [ ] Changeset data structures serialize/deserialize correctly
- [x] **NOTE**: NO real AWS calls during development. All AWS testing uses mock fixtures. Real AWS validation deferred to final human review.

### Gate 5 (after Phase 5): Full CLI
- [x] `iidy-hs --help` output is similarly structured to `iidy --help`
- [ ] Shell completion works for bash/zsh
- [x] All param commands compile and pass mock tests (no real SSM)
- [x] Render command handles stdin, file, and all formats
- [x] Exit codes match (0, 1, 130) — SIGINT handler installed for 130

### Gate 6 (after Phase 6): Production Ready
- [ ] All 98 Rust snapshot files produce identical output from Haskell
- [x] `nix build` produces binary (12MB, dynamically linked)
- [x] No GHC warnings with `-Wall -Wcompat`
- [ ] Memory usage under 512MB for typical operations

## Risk Register

| # | Risk | Impact | Likelihood | Mitigation |
|---|------|--------|------------|------------|
| R1 | JMESPath: no Haskell library | High | Confirmed | Port jamespath-hs from GitHub (126 commits, likely complete), or implement subset (~600 LOC) |
| R2 | tree-sitter-yaml: no Haskell bindings | Medium | Confirmed | Use HsYAML event API with positions instead. Provides line/column. Less granular than tree-sitter AST but sufficient for error reporting |
| R3 | JSON Schema: hjsonschema deprecated | Low | Confirmed | Implement minimal Draft 7 validator (~200 LOC) covering only iidy's actual usage (type, required, properties) |
| R4 | Handlebars vs Mustache | Low | Likely OK | Audit shows iidy uses `{{variable}}` + custom helpers. Port helpers manually (~300 LOC). mustache pkg covers syntax |
| R5 | amazonka API churn | Medium | Low | Pin amazonka 2.0. Auto-generated from AWS service descriptions, stable API |
| R6 | GHC OOM during builds | Medium | Medium | Limit cabal jobs to 4, use -O0 for dev, -split-sections for linking. Monitor with `cabal build -j4 +RTS -M4G` |
| R7 | brick vs ratatui parity | Low | Low | brick is mature (10+ years). May need custom widgets for exact iidy-js output compatibility |
| R8 | Interactive renderer pixel-perfect | High | Medium | The 2438 LOC interactive renderer must match iidy-js output exactly. Use snapshot tests early, iterate |
| R9 | NTP library | Low | Confirmed | Drop feature (minor) or implement minimal SNTP (~100 LOC) |

## Haskell Project Structure

```
iidy-hs/
├── flake.nix
├── cabal.project
├── iidy-hs.cabal
├── app/
│   └── Main.hs
├── src/
│   └── Iidy/
│       ├── Cli.hs                    -- optparse-applicative definitions
│       ├── Types.hs                  -- Core shared types
│       ├── Debug.hs                  -- Debug logging
│       ├── Explain.hs               -- Error code explanations
│       ├── Render.hs                 -- Render command
│       ├── Demo.hs                   -- Demo script execution
│       ├── Yaml/
│       │   ├── Ast.hs               -- AST node types
│       │   ├── Parser.hs            -- HsYAML-based parser with positions
│       │   ├── Detection.hs         -- YAML spec detection
│       │   ├── Emitter.hs           -- iidy-js compatible YAML output
│       │   ├── Engine.hs            -- Two-phase preprocessing
│       │   ├── JMESPath.hs          -- JMESPath evaluator
│       │   ├── Location.hs          -- Position tracking
│       │   ├── PathTracker.hs       -- AST path tracking
│       │   ├── Resolution/
│       │   │   ├── Context.hs       -- TagContext, EnvValues
│       │   │   └── Resolver.hs      -- Tag resolution engine
│       │   ├── Imports/
│       │   │   ├── Types.hs         -- ImportLoader typeclass, ImportRecord
│       │   │   ├── Manifest.hs      -- Import manifest
│       │   │   └── Loaders/
│       │   │       ├── File.hs
│       │   │       ├── Env.hs
│       │   │       ├── Http.hs
│       │   │       ├── S3.hs
│       │   │       ├── Ssm.hs
│       │   │       ├── Cfn.hs
│       │   │       ├── Git.hs
│       │   │       └── Random.hs
│       │   ├── CustomResources/
│       │   │   ├── Params.hs
│       │   │   ├── Expansion.hs
│       │   │   └── RefRewriting.hs
│       │   ├── Handlebars/
│       │   │   ├── Engine.hs
│       │   │   └── Helpers.hs
│       │   └── Errors/
│       │       ├── Ids.hs
│       │       ├── Enhanced.hs
│       │       ├── Display.hs
│       │       └── Wrapper.hs
│       ├── Cfn/
│       │   ├── Types.hs              -- CfnContext, CfnOperation, StackArgs
│       │   ├── Context.hs            -- Context creation
│       │   ├── RequestBuilder.hs
│       │   ├── TemplateLoader.hs
│       │   ├── StackOperations.hs
│       │   ├── Operations/
│       │   │   ├── CreateStack.hs
│       │   │   ├── UpdateStack.hs
│       │   │   ├── DeleteStack.hs
│       │   │   ├── DescribeStack.hs
│       │   │   ├── WatchStack.hs
│       │   │   ├── ListStacks.hs
│       │   │   ├── Changeset.hs
│       │   │   ├── EstimateCost.hs
│       │   │   ├── LintTemplate.hs
│       │   │   ├── GetStackTemplate.hs
│       │   │   ├── DescribeStackDrift.hs
│       │   │   ├── TemplateApproval.hs
│       │   │   ├── ConvertStack.hs
│       │   │   └── InitStackArgs.hs
│       │   ├── TemplateHash.hs
│       │   ├── Constants.hs
│       │   └── Status.hs
│       ├── Aws/
│       │   ├── Config.hs             -- SDK config, credential loading
│       │   ├── CredentialSource.hs
│       │   ├── ClientReqToken.hs
│       │   └── Timing.hs
│       ├── Params/
│       │   ├── Types.hs
│       │   ├── Client.hs
│       │   ├── Get.hs
│       │   ├── Set.hs
│       │   ├── GetByPath.hs
│       │   ├── GetHistory.hs
│       │   └── Review.hs
│       └── Output/
│           ├── Types.hs              -- OutputData, all data structs
│           ├── Renderer.hs           -- OutputRenderer typeclass
│           ├── Manager.hs            -- DynamicOutputManager
│           ├── Color.hs
│           ├── Theme.hs
│           ├── Terminal.hs
│           ├── Status.hs
│           ├── Spinner.hs
│           ├── AwsConversion.hs
│           └── Renderers/
│               ├── Interactive.hs
│               └── Json.hs
├── test/
│   ├── Main.hs
│   ├── Yaml/
│   │   ├── ParserSpec.hs
│   │   ├── ResolverSpec.hs
│   │   ├── EngineSpec.hs
│   │   ├── PropertyTests.hs
│   │   ├── EquivalenceSpec.hs
│   │   ├── ErrorReportingSpec.hs
│   │   └── TypoDetectionSpec.hs
│   ├── Output/
│   │   ├── InteractiveSpec.hs
│   │   ├── JsonSpec.hs
│   │   └── PixelPerfectSpec.hs
│   └── Golden/
│       └── (snapshot files copied from Rust)
├── test-fixtures/
│   ├── (YAML fixtures copied from Rust)
│   └── example-templates/
└── notes/
    ├── module-inventory.md
    ├── ecosystem-audit.md
    ├── cli-ui-spec.md
    └── test-inventory.md
```

## Dependency List (cabal)

```
build-depends:
    -- Core
    base >= 4.17 && < 5
  , text
  , bytestring
  , containers
  , unordered-containers
  , vector
  , mtl
  , transformers
  , stm
  , async
  , unliftio

    -- YAML/JSON
  , aeson
  , HsYAML
  , yaml

    -- AWS
  , amazonka
  , amazonka-cloudformation
  , amazonka-s3
  , amazonka-ssm
  , amazonka-sts
  , amazonka-kms
  , amazonka-sns

    -- CLI
  , optparse-applicative

    -- Terminal UI
  , brick
  , vty
  , vty-crossplatform
  , ansi-terminal

    -- HTTP
  , req
  , http-conduit
  , http-types
  , network-uri

    -- Template
  , mustache

    -- Crypto
  , crypton
  , base64-bytestring
  , base16-bytestring

    -- Utilities
  , uuid
  , random
  , regex-tdfa
  , Diff
  , time
  , directory
  , filepath
  , process
  , temporary
  , Glob
  , word-wrap
  , terminal-size
  , monad-logger
  , casing
```

## Delegation Strategy

**Opus handles**:
- All architectural decisions (typeclass design, monad stack, module interfaces)
- YAML parser design (HsYAML integration for position tracking)
- Tag resolver (complex recursive resolution with context)
- JMESPath evaluator (new implementation)
- YAML emitter (iidy-js compatibility requires precision)
- Interactive renderer (pixel-perfect output matching)
- amazonka integration design (credential flow, config merging)
- Watch-stack event streaming (async patterns)
- Test infrastructure design
- Final snapshot comparison

**Sonnet handles** (after Opus designs interfaces):
- Mechanical type definitions from Rust structs
- Individual import loaders (after Opus defines ImportLoader typeclass)
- Individual CFN operations (after Opus establishes the pattern)
- CLI flag definitions (mechanical translation from clap)
- Color/theme/terminal modules (straightforward)
- Individual test cases (after Opus designs test framework)

## Session Tracking

| Session | Phase | Chunks | Status |
|---------|-------|--------|--------|
| 1 | Phase 1 | 1.1-1.7 | DONE (Gate 1 passed) |
| 2 | Phase 2 | 2.1-2.12 | DONE (all chunks compiled) |
| 3 | Phase 2 (gate) + Phase 3 | Gate 2 + 3.1-3.6 | DONE (27 fixtures pass, output system) |
| 4 | Phase 4 | 4.1-4.15 | DONE (all operations + AWS loaders) |
| 5 | Phase 5 | 5.1-5.11 | DONE (CLI parser, commands, loaders) |
| 6 | Phase 6 | 6.1-6.5 | DONE (81 tests passing) |
| 7 | Phase 6 | 6.6-6.7 | DONE (StackArgsLoader, Main.hs wiring, 89 tests) |
| 8 | Phase 6 | 6.7-6.8 | DONE (remaining stubs, TemplateHash, TODOs fixed, 106 tests) |
| 9 | Polish | help, custom resources, tests | DONE (custom resource expansion, 138 tests) |
| 10 | Polish | emitter, OValue pipeline, snapshot comparison | DONE (36/36 Rust snapshots match, 181 tests) |

**Actual: 10 sessions. 75 modules, ~13,500 LOC, 181 tests**

## Estimated LOC Summary

| Phase | Est. Haskell LOC |
|-------|-----------------|
| Phase 1: Types | 1,600 |
| Phase 2: YAML Engine | 6,050 |
| Phase 3: Output | 2,930 |
| Phase 4: AWS/CFN | 4,450 |
| Phase 5: CLI + Commands | 2,500 |
| Phase 6: Tests | 1,450 |
| **Total** | **~19,000** |

Note: This is higher than the initial 15-25K estimate because it includes test code. Production code alone is ~17,550 LOC, which is ~106% of Rust LOC. Haskell's terser syntax is offset by more explicit type signatures and the verbose amazonka lens API.

## Key Architectural Decisions

1. **Monad stack**: `ReaderT AppEnv IO` as base. AppEnv holds config, AWS clients, output manager. `ExceptT` only where needed for pure error handling.

2. **YAML parsing**: HsYAML event-based API with position tracking (not tree-sitter). HsYAML provides line/column in its event stream, which is sufficient for error reporting. Avoids FFI complexity.

3. **Handlebars**: Use `mustache` package for core syntax. Implement custom helpers as Haskell functions (~300 LOC for case conversion, encoding, string manipulation).

4. **JMESPath**: Implement minimal evaluator from spec (~600 LOC). Cover: field access, array indexing, projections, filters, multiselect, pipe expressions. Skip: user-defined functions.

5. **Output rendering**: No brick/ratatui TUI. The interactive renderer is not actually a TUI app -- it's a sequential ANSI output stream. Use `ansi-terminal` for color codes and `System.IO` for output. Much simpler than a full TUI framework.

6. **JSON Schema**: Minimal validator (~200 LOC). Only validate keywords iidy actually uses in $params.

7. **NTP**: Drop feature. Use system clock only. The timing module exists for clock skew detection which is a nice-to-have, not essential.
