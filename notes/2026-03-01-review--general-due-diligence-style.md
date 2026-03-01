# Due Diligence Review: iidy-hs Codebase

**Date**: 2026-03-01
**Reviewer**: Independent assessment (Claude Opus 4.6)
**Codebase**: iidy-hs (Haskell port of iidy CloudFormation preprocessor/deployer)
**Commit**: d7b0151 (HEAD, main)

---

## Executive Summary

This is a 17,200 LOC Haskell application with 7,300 LOC of tests (845 tests, all
passing) across 84 source modules and 37 test modules. It is a feature-complete
port of a Rust CloudFormation deployment tool (iidy), built entirely by AI agents
(Claude) under human direction over approximately 8 days (Feb 21 - Mar 1, 2026),
totaling 181 commits by a single author.

The code quality is surprisingly high for an AI-generated codebase. The project
compiles with zero warnings under `-Wall -Wcompat`, contains no `undefined`,
`error "TODO"`, or `fromJust` anywhere in the source tree, and has been through
at least three rounds of code review (also AI-driven) that raised the grade from
72 to 90 out of 100. The architecture is clean with well-separated concerns,
and the testing is substantive rather than perfunctory.

The primary risk factors are: (1) the entire codebase was produced in ~8 days
by AI, which is extraordinary velocity for 24,500 total LOC and warrants
skepticism about edge case coverage in areas that lack tests, (2) no human
has deeply reviewed the code beyond directing the AI, (3) several custom
implementations (JMESPath, Handlebars, JSON Schema, NTP) replace battle-tested
libraries and may harbor subtle bugs, and (4) the codebase has never been used
in production. That said, the engineering discipline imposed by the project's
CLAUDE.md rules (zero warnings, no partial functions, green commits only) has
produced a codebase that is more disciplined than many human-written projects.

---

## Scorecard

| Dimension               | Grade | Summary                                                            |
|--------------------------|-------|--------------------------------------------------------------------|
| Code Quality             | B+    | Clean, consistent style; a few large modules and partial functions |
| Test Coverage & Quality  | B     | 845 tests with property tests; some areas undertested              |
| Architecture             | A-    | Well-separated modules, clear data flow, good abstraction choices  |
| Dependency Health        | B+    | Standard Haskell ecosystem; some heavy deps (amazonka, lens)       |
| Build & CI               | B-    | Nix flake works; no CI pipeline; single-arch only                  |
| Documentation            | A     | Exceptional: 13 PRDs, 12 dev docs, 4 ADRs, architecture diagrams  |
| Security                 | B+    | Security model documented; no credentials in code; some concerns   |
| Technical Debt           | A-    | Zero TODOs in source; zero commented-out code; clean codebase      |
| Maintainability          | B     | Good structure but complex custom subsystems raise learning curve   |
| Process & Provenance     | B-    | AI-generated raises trust questions; review loops are a plus       |

---

## Detailed Findings

### 1. Code Quality (B+)

**Strengths**:
- Zero warnings under `-Wall -Wcompat`. This is verified: the build produces
  zero warnings on fresh build.
- No `undefined`, `error "TODO"`, or `fromJust` anywhere in the source tree.
  No `tail` function usage. These were explicitly forbidden in CLAUDE.md and
  the rule was followed.
- Consistent use of `Text` over `String` throughout. Only one occurrence of
  `String` in an IO type signature (in `Demo.hs`).
- Explicit type signatures on all top-level bindings.
- `DerivingStrategies` extension used throughout, making deriving clauses explicit.
- Consistent import style: qualified imports for amazonka, aeson, containers.
  `LambdaCase` and `OverloadedStrings` used consistently.
- Good use of `!` (strict fields) in data types to avoid space leaks.

**Concerns**:
- Three modules exceed the 500 LOC target stated in CLAUDE.md:
  - `Resolver.hs` (873 LOC) -- the YAML tag resolver, inherently complex
  - `Errors/Conversion.hs` (998 LOC) -- error message classification, pattern-heavy
  - `Renderers/Interactive.hs` (1047 LOC) -- terminal rendering, many output cases
  These are justified by their nature (each handles many cases), but the
  Conversion module in particular could potentially be split.
- `T.head` is used in several parsers (`Emitter.hs`, `JMESPath.hs`,
  `Handlebars/Engine.hs`). While each usage is guarded by a preceding
  `T.null` check or pattern match, using `T.uncons` would be safer and
  more idiomatic. In `Emitter.hs` lines 67-71, the guard `T.null s = True`
  on line 65 protects the `T.head` calls, but this is fragile if the guard
  order is ever rearranged.
- `T.last` on line 70 of `Emitter.hs` has the same fragility concern.
- The `extractServiceErrorMessage` function in `app/Main.hs` (lines 112-121)
  parses Amazonka's `Show` output with string matching. This is a hack that
  will break if amazonka changes its Show instance format. A proper approach
  would use the ServiceError record fields directly.

**Code samples demonstrating quality**:
- `/home/tavis/src/iidy-hs/src/Iidy/Cfn/Operations/CreateStack.hs` (82 LOC):
  Clean, well-documented, clear step numbering in comments.
- `/home/tavis/src/iidy-hs/src/Iidy/Yaml/OValue.hs` (110 LOC): Simple,
  focused module with smart constructors and clear documentation.
- `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackOperations.hs` (371 LOC):
  Well-structured polling logic with Set-based deduplication.

### 2. Test Coverage & Quality (B)

**Strengths**:
- 845 tests, all passing. Test/source ratio is 7,304/17,200 = 42% by LOC.
- 37 test modules covering distinct functional areas.
- Property-based tests (`Test.PropertyTest`, 392 LOC) cover OValue round-trips,
  emitter stability, handlebars passthrough, error ID bijection, and status
  classification. The `Arbitrary OValue` instance uses bounded depth to prevent
  infinite generation -- good practice.
- Snapshot comparison against the Rust reference implementation
  (`scripts/snapshot-compare.sh`, `scripts/error-snapshot-compare.sh`) provides
  behavioral verification across 37 render fixtures and 49 error fixtures.
- Test data builders in `Test.Shared` (472 LOC) for all 26 OutputData types
  enable easy test construction without repetitive boilerplate.
- Mock-based testing of AWS polling via dependency injection
  (`pollForCompletionWith` in `StackOperations.hs`) is a good design.
- The `ResolverTest.hs` (1,496 LOC) is the largest test module and provides
  thorough coverage of the YAML tag resolution engine with 60+ test cases
  including edge cases.

**Concerns**:
- No integration tests that exercise the full CLI pipeline (parse args -> load
  YAML -> preprocess -> emit). The `IntegrationTest.hs` tests only the output
  pipeline (OutputData -> Renderer), not end-to-end command execution.
- Import loader tests (`ImportLoaderTest.hs`, `AwsLoaderTest.hs`) test type
  parsing and dispatch but cannot test actual AWS API calls (by design, as
  the project uses no real AWS). This is a gap that would only be caught by
  live testing.
- Custom implementations (JMESPath, Handlebars, JSON Schema) have unit tests
  but no fuzzing or adversarial input testing.
- The NTP client (`Aws/Timing.hs`) has no tests at all -- only a `mockTimeProvider`
  for other modules' tests.
- No test for the SIGINT handler or signal handling behavior.
- Some test modules have orphan instances (`{-# OPTIONS_GHC -Wno-orphans #-}`
  in PropertyTest.hs), though this is standard practice for test QuickCheck
  instances.

### 3. Architecture (A-)

**Strengths**:
- Clean separation into well-defined subsystems:
  - `Yaml.*` -- YAML preprocessing (parser, resolver, emitter, imports)
  - `Cfn.*` -- CloudFormation operations (context, request building, polling)
  - `Output.*` -- Rendering pipeline (types, interactive, JSON, color, theme)
  - `Aws.*` -- AWS configuration (credentials, STS, timing)
  - `Cli.*` -- Command-line interface (parser, help)
- The `OutputData` ADT (26 constructors) provides a clean boundary between
  business logic and rendering. Operations emit `OutputData` values through
  a callback; renderers consume them. This decouples operations from output
  format entirely.
- The `OValue` type preserves insertion order for YAML mappings, which is
  critical for CloudFormation template fidelity. This was a good design
  decision (ADR-002 documents the rationale).
- Dependency injection for testability: `pollForCompletionWith` takes an
  event-fetching IO action rather than requiring a full AWS context.
- The `TimeProvider` abstraction cleanly separates NTP-backed time (for write
  operations where drift matters) from system time (for read-only operations).
- The `PollConfig` record with callbacks is a flexible design for the polling
  loop that avoids a complex monad transformer stack.

**Concerns**:
- The monad stack is plain `IO` with context passed explicitly (no `ReaderT`).
  This is a pragmatic choice that avoids complexity but means every function
  that needs context must thread `CfnContext` manually. For a tool of this
  size it works fine, but scaling would be harder.
- Terminal status lists are duplicated between `Context.hs` (`allTerminalStatuses`,
  `createTerminalStatuses`, etc.) and `Status.hs` (`terminalResourceStatuses`,
  `terminalStackStatuses`). All the `*TerminalStatuses` functions in Context.hs
  are just `= allTerminalStatuses`, making the duplication pointless -- but also
  harmless. The Status.hs module has its own separate list that is slightly
  different (excludes `REVIEW_IN_PROGRESS`). This should be consolidated.
- Custom implementations of JMESPath (~365 LOC), Handlebars (~755 LOC), and
  JSON Schema (~170 LOC) are all reasonable given the specific semantics iidy
  requires, but they represent ongoing maintenance surface that a library
  would handle for free.

### 4. Dependency Health (B+)

**Strengths**:
- Dependencies are all from the standard Haskell ecosystem and well-maintained:
  aeson, amazonka, optparse-applicative, HsYAML, tasty, etc.
- No exotic or unmaintained packages.
- `crypton` (not `cryptonite`) is the correct modern choice for cryptography.
- Test dependencies are minimal: tasty, QuickCheck, temporary.

**Concerns**:
- `amazonka` is a heavy dependency tree (amazonka, amazonka-cloudformation,
  amazonka-s3, amazonka-ssm, amazonka-sts, amazonka-sns). This is necessary
  for the domain but makes builds slow and the binary large.
- `lens` is imported but usage appears limited to a few `Control.Lens`
  operations in `Changeset.hs` (`set`, `view`). The full `lens` package
  is heavy; `microlens` or manual record access would be lighter.
- `regex-posix` is used only in `JsonSchema.hs` for the `pattern` keyword.
  This pulls in POSIX regex which has known issues with backtracking on
  adversarial inputs.
- `yaml` (libyaml bindings) is listed as a dependency but `HsYAML` is the
  actual YAML parser used throughout the codebase. The `yaml` package appears
  to be used only in `ConvertStack.hs` for `Data.Yaml` decoding. Having two
  YAML libraries is wasteful.

### 5. Build & CI (B-)

**Strengths**:
- Nix flake (`flake.nix`) provides reproducible builds with pinned nixpkgs.
- `cabal build` and `cabal test` both succeed with zero warnings.
- `nix build` produces a working binary.
- Build configuration is minimal and clean (`cabal-version: 2.4`, GHC2021).

**Concerns**:
- No CI pipeline (no GitHub Actions, no Buildkite, no Nix CI). The project
  relies entirely on manual/AI-driven verification.
- `flake.nix` hardcodes `system = "x86_64-linux"` -- no macOS or aarch64 support.
- No `flake.lock` was checked (but would be auto-generated by Nix).
- No benchmarks or performance regression tests.
- The dev shell includes all test dependencies mixed with library deps
  (single `haskellDeps` list), which is fine for a small project but
  unclean for distribution.

### 6. Documentation (A)

**Strengths**:
- Exceptional documentation for a project of this size:
  - 13 PRD documents in `docs/requirements/` (~9,500 lines total) covering
    every feature with user stories and acceptance criteria.
  - 12 developer docs in `docs/dev/` covering architecture, codebase guide,
    AWS config, output pipeline, custom resources, testing, Rust compatibility.
  - 4 Architecture Decision Records (ADRs) in `docs/dev/adr/`.
  - Security model documented in `docs/SECURITY.md` (164 lines).
  - Known divergences documented in `DIVERGENCES.md` (104 lines).
  - Command reference in `docs/command-reference.md`.
  - Progress log (`progress.log`, 72 entries) showing chronological development.
- In-code documentation is good: module-level haddock comments, step-by-step
  comments in complex functions (e.g., `createStack`), provenance comments
  citing source-of-truth files (e.g., terminal status lists citing `iidy-js`).

**Concerns**:
- The documentation was generated by AI and optimized for AI consumption (the
  PRDs in particular are structured for LLM context windows). A human developer
  might find them verbose.
- `WORKPLAN.md` has been repurposed from a development workplan to a requirements
  documentation tracker. The original development phases are no longer visible
  in the file, which loses project history.

### 7. Security (B+)

**Strengths**:
- Import security model is well-designed and documented: remote templates
  cannot access local files, environment variables, or git metadata
  (`docs/SECURITY.md`). The `isLocalOnly` / `isRemoteBase` checks in
  `Imports/Types.hs` are clean and correct.
- No credentials, API keys, or secrets anywhere in the codebase.
- The `mask-secrets` flag for the demo command sanitizes AWS account numbers
  and ARNs from output.
- Credential provenance tracking (`CredentialSource`, `CredentialSourceStack`)
  shows users exactly which credential source is being used.
- `AWS_PROFILE` is set via `setEnv` (not baked into the binary).

**Concerns**:
- `setEnv "AWS_PROFILE"` in `Aws/Config.hs` line 47 modifies the global
  process environment. In a multi-threaded context this is unsafe (though
  for a CLI tool it is acceptable). The `setEnv` function from `System.Environment`
  is not thread-safe in Haskell.
- The NTP client (`Aws/Timing.hs`) makes unencrypted UDP connections to
  `pool.ntp.org`. This is standard for NTP but could be spoofed by a network
  attacker. The impact is limited to event timestamps being slightly wrong.
- `regex-posix` in JSON Schema validation (`CustomResources/JsonSchema.hs`)
  is vulnerable to ReDoS (catastrophic backtracking) on adversarial patterns.
  Since schema patterns are defined by template authors (trusted in the local
  case), this is low risk but worth noting.
- No input length limits on YAML files, import chains, or template strings.
  A deeply nested YAML file or import chain could exhaust stack or memory.

### 8. Technical Debt (A-)

**Strengths**:
- Zero `TODO` comments in source code.
- Zero `FIXME`, `HACK`, `XXX`, or `WORKAROUND` comments.
- Zero `undefined` or `error "TODO"` placeholders.
- Zero commented-out code blocks detected.
- Clean git history with descriptive commit messages.
- `DIVERGENCES.md` explicitly tracks intentional behavioral differences from
  the Rust reference, which is excellent practice.

**Concerns**:
- The `extractServiceErrorMessage` function in `Main.hs` (parsing Show output
  with string matching) is the closest thing to a hack in the codebase.
- Two minor TODOs exist in `DIVERGENCES.md` (lines 75 and 92-93) suggesting
  upstream Rust fixes. These are documentation TODOs, not code debt.
- The terminal status list duplication between `Context.hs` and `Status.hs`
  is mild structural debt.

### 9. Maintainability (B)

**Strengths**:
- Module organization follows a clear domain hierarchy that maps to the
  feature set (Yaml/*, Cfn/*, Output/*, Aws/*, Cli/*).
- Most modules are small and focused (median ~100 LOC). The smallest is
  `Types.hs` at 18 LOC; only 3 modules exceed 500 LOC.
- Test modules are named consistently (`Test.XxxTest`) and each exports
  a single test tree that is composed in `test/Main.hs`.
- The `Test.Shared` module provides reusable test data builders that make
  writing new tests straightforward.
- Developer documentation provides onboarding material for new contributors.

**Concerns**:
- The custom JMESPath, Handlebars, and JSON Schema implementations are
  complex subsystems (combined ~1,290 LOC) that a new maintainer would need
  to understand deeply. No specification references are included in the code.
- The `Errors/Conversion.hs` module (998 LOC) is a massive pattern-matching
  function that classifies error messages. Understanding the error taxonomy
  requires reading both this module and `Errors/Enhanced.hs`, `Errors/Ids.hs`,
  and `Errors/Display.hs`.
- The codebase is a port that must maintain behavioral parity with both a
  Rust implementation and an original JavaScript implementation. Any
  maintainer needs access to both reference codebases to understand edge
  cases.
- The project was built by AI in a rapid loop. A human maintainer would need
  to build mental models that the AI was able to bypass by having full
  codebase context in its window. The documentation helps but is not a
  substitute for the "build it yourself" understanding.

### 10. Process & Provenance (B-)

**Key observations**:
- **All 181 commits are by a single author** ("Tavis Rudd"), but the commit
  messages, CLAUDE.md, RALPH.md, and MEMORY.md make clear that the actual code
  was written by Claude (Anthropic's AI) running in an automated loop ("ralph loop").
- **The codebase was produced in approximately 8 calendar days** (Feb 21 - Mar 1, 2026),
  with the bulk (117 commits) on Feb 21-22 alone. This is ~24,500 LOC (source +
  tests) in 8 days, which is physically impossible for a single human developer
  and confirms AI generation.
- **The development process shows discipline**:
  - Phased approach (16 phases) with gates and verification.
  - Green commits only (all tests pass at each commit).
  - Three rounds of code review (also AI-driven) with documented findings
    and fixes, raising the score from 72 to 90.
  - Snapshot comparison against the reference Rust implementation.
  - Progress logging with timestamps.
- **The review loop process is novel**: The project used AI reviewing AI,
  with each review round producing a handoff document listing findings and
  fixes. 14 review rounds in the final loop is thorough, though all rounds
  were conducted by the same system that wrote the code.
- **No independent human code review is evident**. The human's role appears
  to have been directing priorities, imposing coding standards (CLAUDE.md),
  and live-testing against real AWS.

**Trust implications**:
- AI-generated code can be syntactically perfect while having subtle semantic
  errors. The snapshot comparison against the Rust reference provides some
  confidence, but only for behaviors covered by the 37+49 fixtures.
- The three review loops provide additional coverage, but an AI reviewing its
  own code has blind spots different from those of a human reviewer.
- The 845 tests provide meaningful regression protection, but the absence of
  fuzzing, end-to-end CLI tests, and live AWS integration tests leaves gaps.

---

## Risk Register

| # | Risk                                           | Severity | Likelihood | Mitigation                                    |
|---|------------------------------------------------|----------|------------|-----------------------------------------------|
| 1 | Custom JMESPath/Handlebars/Schema have edge    | High     | Medium     | Fuzz testing; compare against spec            |
|   | case bugs not caught by unit tests             |          |            | test suites (JMESPath compliance tests)        |
| 2 | No CI pipeline; regression could be introduced | High     | High       | Set up GitHub Actions with `cabal test`        |
| 3 | `extractServiceErrorMessage` breaks on amazonka| Medium   | Medium     | Rewrite to use ServiceError record fields      |
|   | version upgrade                                |          |            |                                                |
| 4 | setEnv in multi-threaded context is unsafe      | Medium   | Low        | Document single-threaded assumption;           |
|   |                                                |          |            | consider IORef-based approach                  |
| 5 | NTP client is unencrypted and unspoofable       | Low      | Low        | Document as known limitation; timestamps       |
|   |                                                |          |            | are for display only, not security             |
| 6 | regex-posix vulnerable to ReDoS                | Medium   | Low        | Add timeout or switch to RE2-based library     |
| 7 | No production deployment history                | High     | N/A        | Staged rollout with canary testing             |
| 8 | AI-generated code may have subtle semantic bugs | Medium   | Medium     | Human code review of critical paths            |
|   | in untested paths                              |          |            | (polling, changeset, import resolution)        |
| 9 | Two YAML libraries (HsYAML + yaml/libyaml)     | Low      | High       | Remove `yaml` dep; use HsYAML throughout      |
| 10| Single-arch Nix flake (x86_64-linux only)      | Medium   | High       | Add `flake-utils` for multi-platform           |

---

## Strengths

1. **Zero warnings, zero partial functions, zero TODOs** -- the coding standards
   in CLAUDE.md were actually enforced, resulting in an unusually clean codebase.

2. **Output pipeline architecture** -- the `OutputData` ADT + callback pattern
   cleanly separates business logic from rendering, making it trivial to add new
   output formats.

3. **Comprehensive documentation** -- 13 PRDs + 12 dev docs + 4 ADRs is more
   documentation than most production Haskell projects have. The DIVERGENCES.md
   tracking known behavioral differences is excellent practice.

4. **Behavioral verification against reference** -- snapshot comparison against
   the Rust implementation's test output provides real confidence that the port
   is faithful.

5. **Property-based testing** -- the QuickCheck properties cover round-trip
   invariants, emitter stability, and classification functions, catching classes
   of bugs that unit tests miss.

6. **Review loop discipline** -- three rounds of AI code review with documented
   findings and fixes shows a rigorous quality process, even if it is AI-on-AI.

7. **Dependency injection for testability** -- `pollForCompletionWith` and
   `mockTimeProvider` show that testability was considered in the design.

---

## Recommendations (prioritized)

1. **Set up CI immediately** (Critical). There is no automated build or test
   pipeline. A single `cabal test` in GitHub Actions would prevent regressions.

2. **Add end-to-end CLI tests** (High). Exercise the full pipeline from command
   line arguments to rendered output. The snapshot comparison scripts exist but
   are not part of the automated test suite.

3. **Human code review of critical paths** (High). A Haskell-experienced human
   should review: the polling loop (`StackOperations.hs`), changeset operations
   (`Changeset.hs`), import resolution (`Resolver.hs`), and credential handling
   (`Config.hs`). These are the areas where subtle bugs would have the highest
   impact.

4. **Add fuzz testing for custom parsers** (Medium). The JMESPath parser,
   Handlebars parser, and YAML emitter would benefit from QuickCheck or
   hedgehog fuzzing with arbitrary strings to find edge cases.

5. **Fix `extractServiceErrorMessage`** (Medium). Replace Show-output parsing
   with proper ServiceError field access.

6. **Consolidate terminal status lists** (Low). Merge `Context.hs` and
   `Status.hs` terminal status definitions into a single source of truth.

7. **Replace `T.head`/`T.last` with pattern matching** (Low). Use `T.uncons`
   and safe alternatives in `Emitter.hs` and parser modules to eliminate
   reliance on guard ordering for safety.

8. **Make Nix flake multi-platform** (Low). Add `flake-utils` and support
   `aarch64-linux`, `x86_64-darwin`, and `aarch64-darwin`.

9. **Remove duplicate YAML library dependency** (Low). Eliminate `yaml`
   (libyaml) dependency and use `HsYAML` consistently.

10. **Consider replacing `lens` with `microlens`** (Low). The full `lens`
    package is heavy for the 2-3 uses in the codebase.

---

## Appendix: Sampling Methodology

The following files were read in full or sampled during this review:

**Project files**: `iidy-hs.cabal`, `flake.nix`, `WORKPLAN.md`, `DIVERGENCES.md`,
`CLAUDE.md`, `RALPH.md`, `MEMORY.md`, `progress.log`, `docs/SECURITY.md`

**Source modules (15 sampled)**:
- `app/Main.hs` (513 LOC) -- entry point, command dispatch
- `src/Iidy/Types.hs` (18 LOC) -- core types
- `src/Iidy/Yaml/OValue.hs` (110 LOC) -- ordered value type
- `src/Iidy/Yaml/Emitter.hs` (249 LOC) -- YAML emitter
- `src/Iidy/Yaml/JMESPath.hs` (365 LOC) -- custom JMESPath impl
- `src/Iidy/Yaml/Handlebars/Engine.hs` (371 LOC) -- custom Handlebars
- `src/Iidy/Yaml/Resolution/Resolver.hs` (873 LOC) -- tag resolver
- `src/Iidy/Yaml/Errors/Conversion.hs` (998 LOC) -- error classification
- `src/Iidy/Yaml/Imports/Types.hs` (109 LOC) -- import security model
- `src/Iidy/Cfn/Types.hs` (124 LOC) -- CFN operation types
- `src/Iidy/Cfn/Context.hs` (171 LOC) -- operation context
- `src/Iidy/Cfn/StackOperations.hs` (371 LOC) -- polling, events
- `src/Iidy/Cfn/Operations/CreateStack.hs` (82 LOC) -- stack creation
- `src/Iidy/Cfn/Operations/Changeset.hs` (448 LOC) -- changeset ops
- `src/Iidy/Cfn/Operations/ConvertStack.hs` (590 LOC) -- stack conversion
- `src/Iidy/Cfn/RequestBuilder.hs` (300+ LOC) -- API request building
- `src/Iidy/Cfn/Status.hs` (49 LOC) -- status classification
- `src/Iidy/Aws/Config.hs` (219 LOC) -- AWS environment setup
- `src/Iidy/Aws/Timing.hs` (131 LOC) -- NTP client
- `src/Iidy/Output/Types.hs` (456 LOC) -- output data types
- `src/Iidy/Output/Renderers/Interactive.hs` (1047 LOC) -- terminal renderer
- `src/Iidy/Output/Renderers/Json.hs` (521 LOC) -- JSON renderer
- `src/Iidy/Cli/Parser.hs` (628 LOC) -- CLI argument parsing
- `src/Iidy/Yaml/CustomResources/JsonSchema.hs` (170 LOC) -- schema validation

**Test modules (7 sampled)**:
- `test/Main.hs` (82 LOC) -- test runner
- `test/Test/Shared.hs` (472 LOC) -- test data builders
- `test/Test/WatchStackTest.hs` (252 LOC) -- polling tests
- `test/Test/PropertyTest.hs` (392 LOC) -- QuickCheck properties
- `test/Test/ResolverTest.hs` (1,496 LOC) -- resolver unit tests
- `test/Test/ErrorClassificationTest.hs` (336 LOC) -- error classification
- `test/Test/StackOpsConverterTest.hs` (158 LOC) -- AWS type converters

**Searches performed**:
- `undefined` -- 0 occurrences in source (2 in tests/comments, both benign)
- `error "TODO"` -- 0 occurrences
- `fromJust` -- 0 occurrences
- `tail` (partial) -- 0 occurrences in source
- `TODO` -- 0 occurrences in source
- `HACK`/`FIXME`/`XXX`/`WORKAROUND` -- 0 occurrences
- `secret`/`password`/`credential`/`api.?key` -- only appropriate uses
  (credential source tracking, mask-secrets flag)
- `hardcoded`/`hardcode` -- 0 occurrences
