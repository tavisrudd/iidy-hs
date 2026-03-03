# iidy → Haskell Port: Feasibility Analysis & Rough Plan

**Date**: 2026-02-21
**Session**: `4cb08e5f-61d8-46b4-a315-59aec9fa4698`
**References**:
- `notes/iidy-characterization.md` -- 39K LOC Rust codebase breakdown
- `notes/iidy-zig-port-analysis.md` -- why Zig fails (ecosystem gaps) and what's portable
- `notes/dss-pubsub-port-analysis.md` -- speedup ratios from the pubsub ports
- iidy source: `/home/tavis/src/iidy/`
- Haskell port repo: `~/src/iidy-hs/` (create this repo, not under centaur-analysis)

## Context

After porting dss-pubsub to Python/TypeScript/Zig, we explored porting iidy (39K LOC Rust CloudFormation deployment tool) to other languages. Zig was ruled out due to massive ecosystem gaps (no AWS SDK, no YAML parser, no handlebars, no async runtime). Haskell is viable because the ecosystem covers every major dependency.

This is an experiment to see if Opus can autonomously manage a full, high-quality port of a production 39K LOC Rust codebase to Haskell -- including planning, architectural decisions, implementation, and quality gates -- with minimal human intervention. The human approves the workplan and reviews the final result; everything in between is Opus-managed.

This tests a harder claim than the dss-pubsub ports: not just "AI can translate code fast" but "AI can manage a large, multi-session software project end-to-end." The port must be functionally and UI equivalent to the Rust version, passing its snapshot output tests. If it works, it's a strong data point for the paper. If it fails, where and how it fails is equally valuable.

### Why Haskell works where Zig doesn't

| Dependency | Rust crate | Haskell equivalent |
|---|---|---|
| AWS SDK (7 services) | aws-sdk-* | `amazonka-*` (full coverage) |
| YAML parsing | serde_yaml, tree-sitter-yaml | tree-sitter C FFI (preserve location tracking), `aeson` |
| Async runtime | tokio | Built-in green threads, `async`, STM |
| Terminal UI | ratatui, crossterm | `brick` (direct equivalent) |
| HTTP client | reqwest | `http-client`, `wreq` |
| CLI parsing | clap | `optparse-applicative` |
| Templating | handlebars | `mustache` or `stache` |
| JSON Schema | jsonschema | `hjsonschema` |
| JSON queries | jmespath | Custom or `aeson-lens` |
| Error handling | anyhow/thiserror | `ExceptT`, `Either` |

The only real gap: tree-sitter FFI. The pragmatic choice is to use Haskell's native `yaml` package instead and build location tracking on top.

### Translation patterns

| Rust | Haskell |
|---|---|
| `Result<T, E>` | `Either e a` / `ExceptT e IO a` |
| Trait objects (`dyn Trait`) | Typeclasses / existential types |
| `async`/`.await` | `IO` / `async` library / green threads |
| Ownership/borrowing | Immutability (no concern) |
| `Arc<Mutex<T>>` | `TVar` (STM) or `MVar` |
| Visitor pattern (YAML resolution) | Recursion schemes / catamorphisms |
| Scoped resolution context | `Reader` monad / `ReaderT` |
| `enum` with variants | ADTs (algebraic data types) |
| Imperative loops | `traverse`, `mapM`, folds |
| Builder pattern (AWS requests) | Record syntax / lenses |

## Key Architecture Decisions (for the executing agent)

### Build tooling
**Nix** for toolchain and dependency management. Use a `flake.nix` with `haskell.nix` or `nixpkgs` Haskell infrastructure for reproducible builds. Cabal as the build system under Nix. No stack. The repo already has a `flake.nix` with devShells for the TS and Zig ports -- add a `haskell` devShell alongside them. Pin GHC version, all Hackage deps, and the tree-sitter C library in the Nix flake.

### Build resource limits
The dev machine has 28GB RAM / 24 cores but runs near capacity (20GB used, 7.5GB in swap during typical sessions). GHC and especially linking large Haskell binaries can OOM. Configure:
- **cabal**: `jobs: 4` in `~/.cabal/config` or `cabal.project` (not `$ncpus` -- 24 parallel GHC invocations will OOM)
- **GHC options**: add `-with-rtsopts=-M4G` to limit RTS heap; use `+RTS -A64m` for GC tuning during builds if needed
- **Linking**: use `-split-sections` to reduce linker memory. Avoid `-threaded -O2` during dev builds -- save optimization for CI/release. Add `ghc-options: -O0` to cabal.project for local dev.
- **Nix**: if using `haskell.nix`, set `maxBuildJobs = 4;` in the flake to limit parallelism during `nix build`

### Monad stack
`ReaderT Config IO` as the base, with `ExceptT` for error handling where needed. Don't over-engineer the monad stack -- keep it simple, add transformers only when the code demands it.

### YAML parsing
Use tree-sitter via FFI to C, matching the Rust version's approach. Haskell's FFI to C is mature and well-documented. Bind `tree-sitter` core + `tree-sitter-yaml` grammar. This preserves the precise location tracking that powers iidy's error reporting -- the whole point of using tree-sitter over a simpler YAML parser. Check for existing Haskell tree-sitter bindings first (explore agent task); if none exist, write minimal FFI bindings to the C API.

### Module structure
Mirror iidy's module layout loosely but adapt to Haskell conventions:
- `Iidy.Yaml.Parser`, `Iidy.Yaml.Resolver`, `Iidy.Yaml.Engine`
- `Iidy.Cfn.*` for CloudFormation operations
- `Iidy.Output.*` for renderers
- `Iidy.Aws.*` for SDK wrappers

## Rough Plan

### Phase 0: Exploration (~1 session)
- Explore agent reads the full iidy source tree
- Map every module to its Haskell equivalent
- Identify the dependency graph between modules
- Produce a detailed module-by-module porting plan
- Confirm amazonka API coverage for all 7 AWS services used

### Phase 1: Project skeleton + types (~1 session)
- cabal project setup, CI config
- Core types: YAML AST, Message types, Config, error types
- LogLevel, stack-args types, CloudFormation types
- **Delegation**: Opus for type design decisions, Sonnet for mechanical setup

### Phase 2: YAML preprocessing engine (~3-4 sessions)
The algorithmic core. Port in order:
1. YAML parsing + AST representation
2. Import manifest + loader interface (typeclass)
3. Resolution context (Reader monad)
4. Tag resolver (recursion/visitor pattern → catamorphism)
5. Two-phase engine orchestration
6. File import loader (only real loader initially)
7. Error reporting with location context
- **Delegation**: Opus for all architectural decisions (typeclass design, monad stack, tree-sitter FFI bindings, resolver strategy). Sonnet for mechanical module implementations after Opus has designed the interfaces.

### Phase 3: CloudFormation integration (~3-4 sessions)
- amazonka client setup + credential handling
- Stack operations (create, update, delete, describe)
- Changeset workflow
- Event polling + streaming
- Template approval (S3-backed)
- **Delegation**: Opus for amazonka integration design, credential architecture, and async event streaming. Sonnet for individual stack operation implementations once the pattern is established.

### Phase 4: CLI + Output (~2-3 sessions)
- optparse-applicative CLI definition
- Plain text renderer
- JSON renderer
- Interactive terminal renderer (brick) -- this is the largest single module
- **Delegation**: Opus for brick UI architecture and output renderer abstraction design. Sonnet for CLI flag definitions and plain/JSON renderers.

### Phase 5: SSM + ancillary (~1-2 sessions)
- SSM Parameter Store operations
- HTTP/git/S3 import loaders
- Handlebars/mustache integration
- **Delegation**: Opus for import loader typeclass refinement and handlebars integration strategy. Sonnet for individual loader implementations.

### Phase 6: Integration testing + polish (~2-3 sessions)
- End-to-end tests against localstack or mocked AWS
- Error message quality review
- Performance profiling
- Snapshot test comparison against Rust output
- **Delegation**: Opus for test architecture and snapshot comparison strategy. Sonnet for writing individual test cases.

**Total: ~13-18 sessions**

## Effort Estimates

### AI-assisted (from this plan)
- ~13-18 sessions
- ~8-12 hours wall clock (assuming ~40 min/session average)
- Would produce ~15-25K LOC Haskell (expect ~60-70% of Rust LOC due to terser syntax, no ownership boilerplate)

### Human (original author, knows Rust well, moderate Haskell)
- YAML engine: 3-4 weeks
- CloudFormation integration: 2-3 weeks
- CLI + Output: 2-3 weeks
- SSM + ancillary: 1 week
- Integration + polish: 1-2 weeks
- **Total: ~10-14 weeks (~400-550 hours)**
- Assumes the developer knows Haskell moderately (has used it but isn't writing production Haskell daily). The amazonka API and monad stack design would need learning time.

### Human (original author, no Haskell)
- Add 4-6 weeks for Haskell learning (monads, typeclasses, lens, IO)
- **Total: ~14-20 weeks (~550-800 hours)**

### Speedup ratios
| Scenario | AI time | Human time | Ratio |
|---|---|---|---|
| AI vs author (moderate Haskell) | ~10 hrs | ~400-550 hrs | ~45-55x |
| AI vs author (no Haskell) | ~10 hrs | ~550-800 hrs | ~55-80x |

Consistent with the pattern from dss-pubsub: ~40-50x for known-architecture ports, scaling up when the human has a language learning curve.

## Is It Worth Doing?

**For the paper**: Strong data point. A 39K LOC → ~20K LOC cross-language port would be the largest AI-assisted port documented. Shows scaling behavior beyond toy examples.

**For practical use**: Only if you want a Haskell CloudFormation tool. The Rust version works and is maintained.

**For fun**: The YAML engine in Haskell would be genuinely elegant. Recursion schemes for the resolver, Reader monad for scoped context, STM for concurrent event streaming. It's a showcase for Haskell's strengths.

**Recommendation**: If pursuing, start with Phase 0 (exploration) and Phase 2 (YAML engine) as a proof of concept. That's ~4-5 sessions and produces the most interesting code. The CloudFormation/AWS integration is large but mechanical -- only do it if the YAML engine port goes well and you want the full tool.

## Workflow Instructions for Next Agent

**Goal**: The port must be functionally and UI equivalent to the Rust version. Not a subset, not "the interesting parts" -- the full tool, all commands, same output, same interactive terminal UI, same error messages.

**Your first job is NOT to start coding.** Your first job is to produce a detailed, validated workplan with stage gates. Use sub-agents to gather the information you need, then synthesize the plan yourself.

### Step 1: Parallel research (sub-agents)

Launch these sub-agents in parallel. Each writes to a file and returns a summary.

**Agent A: iidy full module inventory** (Sonnet, Explore)
- Read every `.rs` file in the iidy source tree
- Produce a complete module dependency graph
- For each module: LOC, public API surface (exported functions/types/traits), dependencies on other modules, external crate dependencies
- Write to `notes/module-inventory.md`

**Agent B: Haskell ecosystem audit** (Opus)
- For every external Rust crate in iidy's Cargo.toml, find the Haskell equivalent
- Verify each Haskell package exists on Hackage, is maintained, and covers the needed API surface
- Special attention to: amazonka coverage of all 7 AWS services, tree-sitter Haskell bindings (check Hackage, GitHub, any prior art for FFI to tree-sitter C), brick vs ratatui feature parity
- Flag any gaps where no equivalent exists and propose solutions
- Write to `notes/archived/2026-02-21-init-planning--ecosystem-audit.md`

**Agent C: iidy CLI + UI audit** (Sonnet, Explore)
- Document every CLI command, subcommand, and flag from clap definitions
- Document every output format (interactive, JSON, plain)
- Capture the interactive terminal UI behavior: what ratatui renders, event streaming format, color scheme, progress indicators
- Document error message format and the enhanced error context system
- Write to `notes/archived/2026-02-21-init-planning--cli-ui-spec.md`

**Agent D: iidy test inventory** (Sonnet, Explore)
- Catalog every test file, test function, and what it tests
- Note which tests use mocks (mockito), property tests (proptest), snapshot tests (insta), benchmarks (criterion)
- Map each test category to Haskell testing equivalents (hspec, QuickCheck, tasty, etc.)
- Write to `notes/archived/2026-02-21-init-planning--test-inventory.md`

### Step 2: Synthesize the workplan (main context, Opus)

Read all four research files. Produce the detailed workplan:

1. **Module porting order** -- bottom-up dependency order, which modules can be done in parallel
2. **Chunks** -- each chunk is independently testable and produces working code
3. **Stage gates** -- define what "done" means for each phase before proceeding:
   - Phase gate criteria: compiles, tests pass, specific commands work end-to-end
   - **Critical**: iidy's insta snapshot tests capture exact CLI output. The Haskell port must produce byte-identical output. Extract the snapshot fixtures from iidy and use them as golden-file tests for the Haskell port. This is the definitive acceptance criterion for functional equivalence.
   - No phase starts until the previous gate passes
4. **Haskell project structure** -- cabal file, module hierarchy, dependency list
5. **Risk register** -- anything Agent B flagged as a gap, with mitigation plan
6. **Delegation strategy** -- which chunks go to Opus vs Sonnet sub-agents

Write the workplan to `WORKPLAN.md` (the port's own repo, not centaur-analysis). Research notes go to `notes/`.

### Step 3: User review

Present the workplan for approval before any implementation begins. The user will review stage gates and may adjust scope or priorities.

### Step 4+: Autonomous execution via Ralph loop

After the workplan is approved, execute it autonomously. The user should NOT need to babysit. Use the Ralph loop pattern:

**Per-chunk loop:**
1. Read the workplan, find the next incomplete chunk
2. Implement the chunk (using sub-agents where noted in delegation strategy)
3. Run the stage gate checks (compile, tests, snapshot comparison)
4. If gate fails → diagnose, fix, re-run gate (loop until green)
5. Commit the chunk with a descriptive message
6. Update the workplan progress section
7. If context window is getting full → write handoff notes and start a new session via `claude -p --resume`
8. Proceed to next chunk

**Session chaining:**
- Each session reads the workplan first to pick up where the last left off
- Progress is tracked in the workplan file, not in conversation context
- Handoff notes capture any deviations, gotchas, or changed assumptions
- Use `claude -p` (headless) with the workplan as the prompt for unattended execution
- Use `--resume` to continue if a session hits context limits

**Guardrails:**
- Never skip a stage gate. If it fails 3 times on the same issue, stop and write a note for the user rather than thrashing.
- Commit after each green stage gate, not at the end. Small, frequent commits.
- If a Hackage dependency turns out to be broken or insufficient, stop and note it rather than vendoring random code.
- Run `nix build` (not just `cabal build`) at each gate to ensure reproducibility.
- Monitor memory during builds -- if OOM is detected, reduce parallelism further before retrying.

**Human touchpoints (only these):**
1. Workplan approval (Step 3)
2. If a stage gate fails 3x and the agent can't resolve it
3. If an ecosystem gap is discovered that wasn't in the audit
4. Final review of the completed port

## Progress

- [x] Step 1a: Module inventory (sub-agent) → `notes/module-inventory.md`
- [x] Step 1b: Ecosystem audit (sub-agent) → `notes/archived/2026-02-21-init-planning--ecosystem-audit.md`
- [x] Step 1c: CLI + UI spec (sub-agent) → `notes/archived/2026-02-21-init-planning--cli-ui-spec.md`
- [x] Step 1d: Test inventory (sub-agent) → `notes/archived/2026-02-21-init-planning--test-inventory.md`
- [x] Step 2: Synthesize workplan with stage gates → `WORKPLAN.md`
- [x] Step 2.5: Risk review (3 parallel agents) → `notes/workplan-{risk-review,agent-resilience,operational-review}.md`
- [x] Step 3: Workplan approved (user delegated review authority, self-reviewed)
- [ ] Phase 1: Project skeleton + core types
- [ ] Phase 2: YAML preprocessing engine (HsYAML + resolver)
- [ ] Phase 3: Output system (ansi-terminal, NOT brick)
- [ ] Phase 4: CloudFormation integration (amazonka) — all testing offline with mock fixtures
- [ ] Phase 5: CLI + remaining commands
- [ ] Phase 6: Integration testing + polish
- [ ] Final: functionally equivalent to Rust version

## Handoff Notes

### Session 1 (2026-02-21): Planning Complete
- Created `~/src/iidy-hs/` repo with git init
- Ran 4 parallel research agents (module inventory, ecosystem audit, CLI/UI spec, test inventory)
- Synthesized workplan from research
- Ran 3 parallel risk review agents (McConnell risk analysis, agent resilience, operational constraints)
- Key findings from reviews incorporated into WORKPLAN.md header
- **Next session**: Start Phase 1 (Chunk 1.1: Nix flake + cabal setup). First action: `git config --local commit.gpgsign false`, then create flake.nix with Haskell devShell, then skeleton cabal file with all deps, then `cabal build --dry-run` to validate.
- **Testing policy**: All testing offline with mock fixtures. No real AWS calls. Human tests with real AWS at the end only.
- **Token budget**: 5hr/week Claude Max. Ran near budget this session on research. Plan ~2-3 sessions/week, 6-8 weeks total.
