# Due Diligence Code Review: iidy-hs

_Date of audit execution: 2026-03-02_

## A. Executive Summary
Since the last pass, a substantial hardening wave landed (`6feada6`, `e5e1ed7`, `04ca142`, `abc420b`, `dff5ef9`) and the previously blocking parser compatibility issue was then fixed in `1f2e315` (explicit `Data.List (foldl')` import + cross-GHC rule update). Verified locally at current HEAD (`1f2e315`) on GHC 9.6.7: `cabal build all` succeeds and `cabal test all --test-show-details=direct` reports **All 995 tests passed**. Overall assessment: **security/correctness posture is now materially stronger and locally releasable, with remaining risk concentrated in CI matrix depth (single OS/compiler path) rather than immediate correctness blockers**.

## B. Scorecard Table
| Dimension | Grade | One-line Summary |
|---|---|---|
| 1. Code Quality | **B** | Strong type-first style with rapid remediation; cross-GHC compatibility guidance is now explicit in coding standards. |
| 2. Test Coverage & Quality | **A** | Broad and growing suite with strong fixture/property/integration mix; current HEAD passes locally at 995 tests. |
| 3. Architecture | **B+** | Architecture tightened further with strict env-map handling, spinner lifecycle cleanup, and paginated SSM retrieval; only minor output/manifest drift remains. |
| 4. Dependency Health | **B+** | Dependency hygiene and detection tooling improved; residual burden remains in custom engine maintenance. |
| 5. Build & CI | **B-** | Local build/test now pass at HEAD, but CI matrix depth still lags (single OS, no explicit compiler matrix). |
| 6. Documentation | **B-** | Documentation is broad and actively maintained, but metric drift recurs after rapid test-count changes. |
| 7. Security | **A** | Security posture improved again (TLS-capable HTTP loader, S3 size cap, UTF-8 failure handling, NTP underflow guard), with remaining gap in live network-behavior tests. |
| 8. Technical Debt | **B+** | Most high-impact debt findings were retired quickly; remaining debt is mainly verification hardening and documentation freshness. |
| 9. Maintainability | **B** | Maintainability improved via type-safe CLI flags, better lookup structure, and added integration tests; custom subsystems and single-author history remain concentration risks. |
| 10. Process & Provenance | **A-** | Remediation velocity is exceptional and auditable, including fast follow-through on issues surfaced during initial build-out. |

## C. Detailed Findings

### 1) Code Quality
**Strengths**
- Warnings policy is explicitly configured project-wide (`-Wall -Wcompat`) in cabal common stanza ([iidy-hs.cabal:7-8](iidy-hs.cabal:7)).
- Strong explicit-typing posture and mostly idiomatic algebraic modeling (example: structured CLI argument types in [src/Iidy/Cli.hs:249-281](src/Iidy/Cli.hs:249)).
- No `fromJust`/`undefined` usage found in `src/`, `app/`, `test/` via repo-wide search during this audit.
- Recent test cleanup improved warning-robustness across GHC versions by eliminating fragile `let Right ... =` patterns in AWS loader tests ([test/Test/AwsLoaderTest.hs:22-25](test/Test/AwsLoaderTest.hs:22), commit `2461a42`).
- Previous partial indexing in the random loader was replaced with total indexing logic (`drop` + pattern match) ([src/Iidy/Yaml/Imports/Loaders/Random.hs:42-48](src/Iidy/Yaml/Imports/Loaders/Random.hs:42), commit `b21afdd`).
- Parser metadata quality improved: scalar and collection `smEnd` spans are now computed from content/children rather than defaulting to zero-width ([src/Iidy/Yaml/Parser.hs:54-63](src/Iidy/Yaml/Parser.hs:54), [src/Iidy/Yaml/Parser.hs:177-194](src/Iidy/Yaml/Parser.hs:177), commit `6deb078`).

**Concerns**
- Test warning suppression remains in use (`-Wno-orphans`) ([test/Test/PropertyTest.hs:1](test/Test/PropertyTest.hs:1)).
- Module size guideline drift: multiple modules are still far above the stated target in policy docs ([CLAUDE.md:14](CLAUDE.md:14)); e.g., [src/Iidy/Yaml/Errors/Conversion.hs:1](src/Iidy/Yaml/Errors/Conversion.hs:1) (~539 LOC after split), [src/Iidy/Yaml/Resolution/Resolver.hs:1](src/Iidy/Yaml/Resolution/Resolver.hs:1) (869 LOC).
- Cross-GHC compatibility remains a fragile area without CI compiler matrix enforcement; the recent `foldl'` break was fixed quickly by explicit import/rule, but prevention still depends on manual discipline ([src/Iidy/Yaml/Parser.hs:9](src/Iidy/Yaml/Parser.hs:9), [CLAUDE.md:13](CLAUDE.md:13)).

### 2) Test Coverage & Quality
**Strengths**
- Test harness is modular and broad, now with 42 test modules wired through `test/Main.hs` ([test/Main.hs:5-90](test/Main.hs:5), [iidy-hs.cabal:171-213](iidy-hs.cabal:171)).
- Dedicated tests exist for custom implementations: JMESPath ([test/Test/JMESPathTest.hs:11-78](test/Test/JMESPathTest.hs:11)), Handlebars ([test/Test/HandlebarsTest.hs:11-65](test/Test/HandlebarsTest.hs:11)), JSON Schema ([test/Test/JsonSchemaTest.hs:11-112](test/Test/JsonSchemaTest.hs:11)).
- New targeted tests now cover timing subsystem behavior and security controls (import trust gate, regex length caps, HTTP limit constants) ([test/Test/TimingTest.hs:62-185](test/Test/TimingTest.hs:62), [test/Test/SecurityControlsTest.hs:18-193](test/Test/SecurityControlsTest.hs:18)).
- New SSM helper unit tests were added (`ParamsClient`), improving deterministic coverage of parameter-type parsing and history formatting ([test/Test/ParamsClientTest.hs:18-123](test/Test/ParamsClientTest.hs:18), commit `a6c245f`).
- Property-based testing exists and is meaningful (multiple invariants across parser/emitter/helpers/statuses) ([test/Test/PropertyTest.hs:158-193](test/Test/PropertyTest.hs:158)).
- Property suite now includes deeper semantic checks for JMESPath and Handlebars correctness, not only no-crash/idempotence checks ([test/Test/PropertyTest.hs:198-215](test/Test/PropertyTest.hs:198), commit `3467089`).
- Snapshot/fixture style testing is implemented dynamically for render fixtures and error fixtures ([test/Test/FixtureTest.hs:29-42](test/Test/FixtureTest.hs:29), [test/Test/ErrorFixtureTest.hs:18-35](test/Test/ErrorFixtureTest.hs:18)).
- TemplateLoader now has direct integration coverage for render/local/url/failure paths ([test/Test/TemplateLoaderTest.hs:27-230](test/Test/TemplateLoaderTest.hs:27), commit `b8233c3`).
- Previously skipped 11 error fixtures were re-enabled, increasing negative-path coverage ([test/Test/ErrorFixtureTest.hs:18-23](test/Test/ErrorFixtureTest.hs:18), commit `6d20b10`).
- Parser coverage added 14 span-specific tests for scalar/mapping/sequence/tagged/nested span behavior ([test/Test/ParserTest.hs:106-214](test/Test/ParserTest.hs:106), commit `6deb078`).
- SSM pagination correctness now has focused pure tests for >10 parameter scenarios in both SSM path loader and global config parameter application ([test/Test/AwsLoaderTest.hs:149-226](test/Test/AwsLoaderTest.hs:149), [test/Test/GlobalConfigTest.hs:158-209](test/Test/GlobalConfigTest.hs:158), commit `6feada6`).
- Env-map error semantics are now explicitly tested (missing env, non-string value, invalid type, and end-to-end failure path) ([test/Test/StackArgsLoaderTest.hs:88-156](test/Test/StackArgsLoaderTest.hs:88), commit `abc420b`).
- Safety regression tests were added for invalid UTF-8 template inputs and NTP pre-epoch boundary handling ([test/Test/TemplateLoaderTest.hs:205-220](test/Test/TemplateLoaderTest.hs:205), [test/Test/TimingTest.hs:91-112](test/Test/TimingTest.hs:91), commit `e5e1ed7`).
- Current HEAD verification in this session: `cabal test all --test-show-details=direct` reports `All 995 tests passed` on GHC 9.6.7.

**Concerns**
- `GlobalConfig` test quality improved via `applyParams` coverage, but the suite still does not exercise live/paginated fetch behavior through `applyGlobalConfiguration` itself ([test/Test/GlobalConfigTest.hs:17-29](test/Test/GlobalConfigTest.hs:17), [test/Test/GlobalConfigTest.hs:158-209](test/Test/GlobalConfigTest.hs:158)).
- HTTP security tests currently validate configured constants, not live timeout/stream-cutoff behavior ([test/Test/SecurityControlsTest.hs:183-192](test/Test/SecurityControlsTest.hs:183)).

### 3) Architecture
**Strengths**
- Layering is explicit and generally coherent (CLI, YAML engine, CFN operations, output pipeline) ([docs/dev/architecture.md:22-68](docs/dev/architecture.md:22), [app/Main.hs:114-370](app/Main.hs:114)).
- Output pipeline abstraction is well-defined (`OutputData` + dispatch + renderers) ([docs/dev/adr/001-output-pipeline.md:26-43](docs/dev/adr/001-output-pipeline.md:26), [src/Iidy/Output/Manager.hs](src/Iidy/Output/Manager.hs)).
- Recent AWS operation-path improvements reduce avoidable API load and latency: `listStacks` now paginates ([src/Iidy/Cfn/Operations/ListStacks.hs:50-54](src/Iidy/Cfn/Operations/ListStacks.hs:50)); stack-content fetch now runs resources + changesets concurrently ([src/Iidy/Cfn/StackOperations.hs:145-150](src/Iidy/Cfn/StackOperations.hs:145)); redundant stack fetches are avoided via `collectStackContentsWithStack` ([src/Iidy/Cfn/StackOperations.hs:140-144](src/Iidy/Cfn/StackOperations.hs:140), [src/Iidy/Cfn/Operations/DescribeStack.hs:73-74](src/Iidy/Cfn/Operations/DescribeStack.hs:73)).
- Import dispatch architecture now consistently routes through typed classification (`parseImportType`) before loader dispatch, aligning runtime behavior with the documented trust model ([src/Iidy/Yaml/Imports/Loaders/Dispatch.hs:34-55](src/Iidy/Yaml/Imports/Loaders/Dispatch.hs:34), [src/Iidy/Yaml/Imports/Types.hs:56-80](src/Iidy/Yaml/Imports/Types.hs:56), commit `fa767b3`).
- `render:` template path now runs the full YAML preprocessing pipeline (parse -> env injection -> preprocess -> emit), closing a prior core-path gap ([src/Iidy/Cfn/TemplateLoader.hs:69-87](src/Iidy/Cfn/TemplateLoader.hs:69), commit `9ce83cc`).
- `describe-stack --events N` path now paginates conditionally via `fetchStackEventsUpTo`, addressing previous single-page truncation risk ([src/Iidy/Cfn/StackOperations.hs:136-154](src/Iidy/Cfn/StackOperations.hs:136), [src/Iidy/Cfn/Operations/DescribeStack.hs:73](src/Iidy/Cfn/Operations/DescribeStack.hs:73), commit `68ca780` + fix `2b7624b`).
- Global stack-args SSM configuration is now wired into CFN execution flow via `applyGlobalConfiguration` in `runCfnWithArgs` ([app/Main.hs:355-359](app/Main.hs:355), [src/Iidy/Cfn/GlobalConfig.hs:48-56](src/Iidy/Cfn/GlobalConfig.hs:48), commit `a0b1853`).
- Output pipeline migration is progressing: render/get-import/get-stack-template/param commands now emit `OdRawOutput` through dispatch instead of direct stdout writes ([app/Main.hs:221-229](app/Main.hs:221), [app/Main.hs:241-265](app/Main.hs:241), [src/Iidy/Render.hs:38-103](src/Iidy/Render.hs:38), [src/Iidy/GetImport.hs:28-52](src/Iidy/GetImport.hs:28), commit `778348c`).
- Spinner lifecycle cleanup now runs via `finally` and centralized dispatch cleanup for polling paths, reducing terminal corruption on exceptions ([app/Main.hs:169-170](app/Main.hs:169), [app/Main.hs:374-375](app/Main.hs:374), [src/Iidy/Output/Manager.hs:35-39](src/Iidy/Output/Manager.hs:35), commit `04ca142`).
- SSM path fetch architecture is now consistent with existing paginated patterns (`Amazonka.paginate`) in both import and global-config flows ([src/Iidy/Yaml/Imports/Loaders/SsmPath.hs:67-79](src/Iidy/Yaml/Imports/Loaders/SsmPath.hs:67), [src/Iidy/Cfn/GlobalConfig.hs:105-117](src/Iidy/Cfn/GlobalConfig.hs:105), commit `6feada6`).
- Stack-args env map resolution now fails fast on missing/invalid env-map entries instead of silently passing unresolved objects through ([src/Iidy/Cfn/StackArgsLoader.hs:118-143](src/Iidy/Cfn/StackArgsLoader.hs:118), commit `abc420b`).

**Concerns**
- Documented output architecture rule (“no direct putStrLn in commands”) remains partially violated in completion output path ([docs/dev/adr/001-output-pipeline.md:44-45](docs/dev/adr/001-output-pipeline.md:44), [app/Main.hs:323-325](app/Main.hs:323)).
- Import manifest/cycle machinery is largely not exercised in engine flow: `pushImport` used once at root, but no `addRecord`/`popImport` updates during import traversal ([src/Iidy/Yaml/Engine.hs:62-66](src/Iidy/Yaml/Engine.hs:62), [src/Iidy/Yaml/Engine.hs:137-166](src/Iidy/Yaml/Engine.hs:137), [src/Iidy/Yaml/Imports/Manifest.hs:28-33](src/Iidy/Yaml/Imports/Manifest.hs:28), [src/Iidy/Yaml/Imports/Manifest.hs:57-63](src/Iidy/Yaml/Imports/Manifest.hs:57)).

### 4) Dependency Health
**Strengths**
- Dependency set is mostly mainstream and appropriate for the domain (amazonka, aeson, HsYAML, tasty ecosystem) ([iidy-hs.cabal:109-147](iidy-hs.cabal:109), [iidy-hs.cabal:213-235](iidy-hs.cabal:213)).
- Nix flake defines explicit multi-system support targets ([flake.nix:10-12](flake.nix:10)).
- Recent cleanup removed previously flagged unused deps (`amazonka-sns`, `unliftio`, `mtl`) from package definitions ([iidy-hs.cabal:114-143](iidy-hs.cabal:114), commit `fc743ef`).
- Library dependency cleanup continued with `uuid` removed from library deps (still retained in executable) ([iidy-hs.cabal:120-146](iidy-hs.cabal:120), commit `9a34231`).
- `make ci` now includes dependency-hygiene checking (`check-unused-deps`) ([Makefile:30-34](Makefile:30), [scripts/check-unused-deps.sh:212-220](scripts/check-unused-deps.sh:212), commit `64c353b`).

**Concerns**
- Multiple custom re-implementations substitute mature libraries (JMESPath, Handlebars, JSON Schema, base64 helper) increasing long-term correctness burden ([src/Iidy/Yaml/JMESPath.hs:4-7](src/Iidy/Yaml/JMESPath.hs:4), [src/Iidy/Yaml/Handlebars/Engine.hs:4-8](src/Iidy/Yaml/Handlebars/Engine.hs:4), [src/Iidy/Yaml/CustomResources/JsonSchema.hs:1-11](src/Iidy/Yaml/CustomResources/JsonSchema.hs:1), [src/Iidy/Yaml/Handlebars/Helpers.hs:207-209](src/Iidy/Yaml/Handlebars/Helpers.hs:207)).

### 5) Build & CI
**Strengths**
- CI exists and is simple enough to reason about (checkout, nix install/cache, `make ci`) ([.github/workflows/ci.yml:14-23](.github/workflows/ci.yml:14)).
- Strict build target now includes test-suite compilation with `--enable-tests`, improving warning gate coverage ([Makefile:6-8](Makefile:6), commit `8c8711d`).
- Recent CI reproducibility improvement: `cabal update` was removed from `make ci` ([Makefile:27-31](Makefile:27), commit `fc743ef`).
- Latest local verification in this audit session: `cabal build all` succeeds and `cabal test all --test-show-details=direct` passes with `All 995 tests passed` on GHC 9.6.7 at HEAD (`1f2e315`).

**Concerns**
- CI matrix is single-OS (`ubuntu-latest`) despite cross-platform target claims in flake; no Windows/macOS job coverage ([.github/workflows/ci.yml:11](.github/workflows/ci.yml:11), [flake.nix:10](flake.nix:10)).
- No explicit multi-GHC matrix exists in CI, so compatibility issues like the recent Prelude `foldl'` re-export difference are still discovered late in the development loop ([CLAUDE.md:13](CLAUDE.md:13), [.github/workflows/ci.yml:11](.github/workflows/ci.yml:11)).
- No benchmark/perf gate found in CI or build config.

### 6) Documentation
**Strengths**
- Strong documentation footprint: security model, architecture guide, testing guide, ADRs, divergences ([docs/SECURITY.md](docs/SECURITY.md), [docs/dev/architecture.md](docs/dev/architecture.md), [docs/dev/testing-guide.md](docs/dev/testing-guide.md), [docs/dev/adr/001-output-pipeline.md](docs/dev/adr/001-output-pipeline.md), [DIVERGENCES.md](DIVERGENCES.md)).
- Divergence tracking exists and includes rationale ([DIVERGENCES.md:1-4](DIVERGENCES.md:1)).

**Concerns**
- Dev docs were recently updated, but metrics have already drifted again (docs still cite 851 tests while the latest successful baseline in this session is 995) ([docs/dev/codebase-guide.md:9](docs/dev/codebase-guide.md:9), [docs/dev/testing-guide.md:5](docs/dev/testing-guide.md:5), [test/Main.hs:5-90](test/Main.hs:5)).
- Architecture doc states GHC 9.10 ([docs/dev/architecture.md:12](docs/dev/architecture.md:12)), but package config does not pin a specific GHC version in cabal metadata ([iidy-hs.cabal:1-3](iidy-hs.cabal:1)), increasing room for version-drift confusion.
- Some handoff documents have become stale after fast implementation churn (e.g., archived global-SSM handoff still states “not yet ported”) ([notes/handoffs/done/2026-03-01-global-ssm-config.md:21-22](notes/handoffs/done/2026-03-01-global-ssm-config.md:21)).

### 7) Security
**Strengths**
- Security threat model is explicitly documented for import contexts ([docs/SECURITY.md:9-18](docs/SECURITY.md:9), [docs/SECURITY.md:131-139](docs/SECURITY.md:131)).
- Demo file unpacking includes basic path traversal protections (`/` and `..` checks) ([src/Iidy/Demo.hs:148-151](src/Iidy/Demo.hs:148)).
- Git loader command mapping is whitelisted and not arbitrary user shell expansion ([src/Iidy/Yaml/Imports/Loaders/Git.hs:41-47](src/Iidy/Yaml/Imports/Loaders/Git.hs:41)).
- AWS profile selection now avoids process-wide environment mutation by using `ConfigFile.fromFilePath` ([src/Iidy/Aws/Config.hs:43-52](src/Iidy/Aws/Config.hs:43), commit `3726bfd`).
- Import trust model enforcement is now wired into runtime dispatch via `parseImportType` classification gate ([src/Iidy/Yaml/Imports/Loaders/Dispatch.hs:34-37](src/Iidy/Yaml/Imports/Loaders/Dispatch.hs:34), [src/Iidy/Yaml/Imports/Types.hs:77-80](src/Iidy/Yaml/Imports/Types.hs:77), commit `fa767b3`).
- Regex pattern-length guardrail is now applied in both JSON Schema and param `AllowedPattern` validation (`maxRegexPatternLength = 1024`) ([src/Iidy/Constants.hs:51-56](src/Iidy/Constants.hs:51), [src/Iidy/Yaml/CustomResources/JsonSchema.hs:164-170](src/Iidy/Yaml/CustomResources/JsonSchema.hs:164), [src/Iidy/Yaml/CustomResources/Params.hs:109-120](src/Iidy/Yaml/CustomResources/Params.hs:109), commit `fa767b3`).
- HTTP imports now enforce timeout + streaming size limits (aborts before full buffering) ([src/Iidy/Constants.hs:39-45](src/Iidy/Constants.hs:39), [src/Iidy/Yaml/Imports/Loaders/Http.hs:83-112](src/Iidy/Yaml/Imports/Loaders/Http.hs:83), commit `9a34231`).
- Security regression tests now cover trust-gate enforcement and regex-length rejection paths ([test/Test/SecurityControlsTest.hs:29-176](test/Test/SecurityControlsTest.hs:29), commit `0b4fefb` + `9b2ea58`).
- Unknown import prefixes are now rejected instead of silently falling through to file import semantics ([src/Iidy/Yaml/Imports/Types.hs:83-93](src/Iidy/Yaml/Imports/Types.hs:83), [test/Test/SecurityControlsTest.hs:85-107](test/Test/SecurityControlsTest.hs:85), commit `642c9f0`).
- HTTP loader now uses TLS-capable manager creation and shared manager reuse, and parses `.yaml`/`.yml` via YAML parser rather than JSON fallback semantics ([src/Iidy/Yaml/Imports/Loaders/Http.hs:25](src/Iidy/Yaml/Imports/Loaders/Http.hs:25), [src/Iidy/Yaml/Imports/Loaders/Http.hs:53-55](src/Iidy/Yaml/Imports/Loaders/Http.hs:53), [src/Iidy/Yaml/Imports/Loaders/Http.hs:133-147](src/Iidy/Yaml/Imports/Loaders/Http.hs:133), commit `dff5ef9`).
- S3 import loader now enforces the same 10MB maximum response size as HTTP imports ([src/Iidy/Yaml/Imports/Loaders/S3.hs:72-88](src/Iidy/Yaml/Imports/Loaders/S3.hs:72), commit `e5e1ed7`).
- TemplateLoader now fails gracefully on invalid UTF-8 instead of partial decode crash behavior ([src/Iidy/Cfn/TemplateLoader.hs:161-168](src/Iidy/Cfn/TemplateLoader.hs:161), [test/Test/TemplateLoaderTest.hs:205-220](test/Test/TemplateLoaderTest.hs:205), commit `e5e1ed7`).
- NTP parser now guards pre-epoch underflow edge cases and has explicit boundary tests ([src/Iidy/Aws/Timing.hs:119-130](src/Iidy/Aws/Timing.hs:119), [test/Test/TimingTest.hs:91-107](test/Test/TimingTest.hs:91), commit `e5e1ed7`).

**Concerns**
- HTTP-related tests currently validate configuration constants but do not run a live/mock server scenario to verify timeout expiry and mid-stream cutoff behavior end-to-end ([test/Test/SecurityControlsTest.hs:183-192](test/Test/SecurityControlsTest.hs:183), [src/Iidy/Yaml/Imports/Loaders/Http.hs:87-112](src/Iidy/Yaml/Imports/Loaders/Http.hs:87)).

### 8) Technical Debt
**Strengths**
- No `TODO`/`FIXME`/`HACK` comments found in `src/`, `app/`, `test/` during this audit.
- Error handling infrastructure is mature and centralized ([src/Iidy/Yaml/Errors/Conversion.hs](src/Iidy/Yaml/Errors/Conversion.hs), [src/Iidy/Yaml/Errors/Enhanced.hs](src/Iidy/Yaml/Errors/Enhanced.hs)).
- `Errors/Conversion` was decomposed into focused submodules (`Guidance`, `Location`, `LineSearch`), reducing monolithic complexity and clarifying responsibilities ([src/Iidy/Yaml/Errors/Conversion.hs:16-37](src/Iidy/Yaml/Errors/Conversion.hs:16), [src/Iidy/Yaml/Errors/Conversion/Guidance.hs](src/Iidy/Yaml/Errors/Conversion/Guidance.hs), [src/Iidy/Yaml/Errors/Conversion/Location.hs](src/Iidy/Yaml/Errors/Conversion/Location.hs), [src/Iidy/Yaml/Errors/Conversion/LineSearch.hs](src/Iidy/Yaml/Errors/Conversion/LineSearch.hs), commit `6c2a7ef`).
- Partial-function cleanup continued: emitter multiline paths now use a total helper (`safeInit`) instead of `init` ([src/Iidy/Yaml/Emitter.hs:224-230](src/Iidy/Yaml/Emitter.hs:224), commit `e5e1ed7`).

**Concerns**
- Known deferred items tracked in divergences (`TODO` entries) ([DIVERGENCES.md:75](DIVERGENCES.md:75), [DIVERGENCES.md:92](DIVERGENCES.md:92)).
- Global configuration intentionally skips SNS ARN validation (documented in code comments), leaving bad ARN detection to downstream AWS operation failure ([src/Iidy/Cfn/GlobalConfig.hs:77-80](src/Iidy/Cfn/GlobalConfig.hs:77)).

### 9) Maintainability
**Strengths**
- Code organization is predictable; command dispatch and module naming are consistent ([app/Main.hs:114-319](app/Main.hs:114)).
- ADRs and dev docs improve onboarding and decision traceability ([docs/dev/adr/001-output-pipeline.md](docs/dev/adr/001-output-pipeline.md), [docs/dev/architecture.md](docs/dev/architecture.md)).

**Concerns**
- Large module concentration increases cognitive load and blast radius for changes (e.g., [src/Iidy/Yaml/Errors/Conversion.hs](src/Iidy/Yaml/Errors/Conversion.hs), [src/Iidy/Yaml/Resolution/Resolver.hs](src/Iidy/Yaml/Resolution/Resolver.hs)).
- Custom parsers/engines require specialist understanding and ongoing spec-compliance maintenance ([src/Iidy/Yaml/JMESPath.hs:4-7](src/Iidy/Yaml/JMESPath.hs:4), [src/Iidy/Yaml/Handlebars/Engine.hs:4-8](src/Iidy/Yaml/Handlebars/Engine.hs:4)).
- Single-author commit history creates high bus-factor risk (`git shortlog` shows one contributor).

### 10) Process & Provenance
**Strengths**
- Process artifacts are unusually rich (workplan, divergences, trust guide, ADRs) ([WORKPLAN.md](WORKPLAN.md), [DIVERGENCES.md](DIVERGENCES.md), [notes/2026-03-01-process-trust-guide.md](notes/2026-03-01-process-trust-guide.md)).
- Stated coding constitution is explicit and testable ([CLAUDE.md:6-19](CLAUDE.md:6)).
- Finding-resolution turnaround is exceptional: major fix commits were shipped in a tight sequence from 2026-03-01 18:48 through 19:14, covering template preprocessing, approval error propagation, HTTP streaming limits, security hardening tests, event pagination, strict-test build gating, and follow-up platform/test wiring fixes ([git log evidence in methodology](#g-sampling-methodology-audit-trail)).
- A second rapid closure wave continued through 2026-03-01 19:49, adding unknown-prefix hardening, SSM pagination/type correctness, pure-unit coverage for params, and error-conversion modularization.
- A third wave followed immediately (20:00-20:11), closing additional findings via output-pipeline migration work, TemplateLoader integration tests, global SSM config wiring, skipped-fixture re-enable, explain-map optimization, and CLI type safety (`778348c`, `b8233c3`, `a0b1853`, `6d20b10`, `e00f3be`, `7a1a18f`).
- A fourth wave added parser source-span fidelity work with focused tests (`6deb078`) and corresponding handoff/progress updates (`7ef641a`).
- A fifth wave (`6feada6`, `e5e1ed7`, `04ca142`, `abc420b`, `dff5ef9`) rapidly addressed critical/high review findings: SSM pagination, safety hardening, spinner cleanup, strict env-map behavior, and HTTP loader correctness.
- A sixth follow-up commit (`1f2e315`) closed the GHC 9.6 parser compatibility issue immediately by adding explicit `Data.List (foldl')` import and codifying a cross-GHC rule in `CLAUDE.md`.
- Latest CI workflow runs for the newest commits are reported green in the provided workflow screenshot (including `2b7624b` and `8c8711d`).
- Handoff/progress maintenance commits remain tightly coupled to code commits, preserving an auditable closure trail (`60d0f79`, `b9dada0`, `7ef641a`).

**Concerns**
- Provenance is AI-single-author and self-review-heavy; this raises the burden of independent verification for custom correctness/security subsystems ([README.md:15-20](README.md:15), [notes/2026-03-01-process-trust-guide.md:44-50](notes/2026-03-01-process-trust-guide.md:44)).
- Claimed quantitative process facts in user context have drifted from current repo state (commit count now 261 in this checkout).
- Rapid batching in an early-stage codebase can surface short-lived platform-specific integration mismatches before follow-up commits; in this case, the macOS/GHC 9.6 field-ambiguity issue from `68ca780` was fixed quickly by `2b7624b`, and `8c8711d` tightened strict-test build gating.
- The recent parser compatibility issue was fixed quickly, but it still demonstrates that compiler-version verification is a weak pre-merge link without multi-GHC CI coverage ([src/Iidy/Yaml/Parser.hs:9](src/Iidy/Yaml/Parser.hs:9), [.github/workflows/ci.yml:11](.github/workflows/ci.yml:11)).

### Resolution Pace Reflection (Maintenance/Process)
- **What is working**: The team is closing findings at very high speed with auditable, narrowly scoped commits and corresponding handoff artifacts.
- **Calibration context**: this repository was built in a very compressed initial window (late February to March 1, 2026), so many fixes here are expected stabilization during first implementation, not decay from a long-lived production baseline.
- **What changed versus prior assessment**: multiple previously-open high/critical items were resolved in a single rapid burst (SSM pagination, HTTP loader corrections, env-map strictness, spinner cleanup, partial-function/underflow/size-limit hardening).
- **New observation from this wave**: a parser compatibility issue was fixed rapidly (`1f2e315`) and validated locally with full-suite pass (`995` tests).
- **Bottom line**: velocity and fix quality are strong; process maturity now depends on preventing recurrence through broader CI/toolchain coverage rather than ad-hoc catch-up.

---

### Specific Code Samples (high-impact)

**1) Cross-GHC parser compatibility fix landed and validated**
```haskell
import Data.List (foldl')
```
([src/Iidy/Yaml/Parser.hs:9](src/Iidy/Yaml/Parser.hs:9))

```text
All 995 tests passed (0.26s)
```
(from local `cabal test all --test-show-details=direct` at HEAD `1f2e315`)

**2) SSM pagination fix now applied in global config and SSM path loader**
```haskell
-- src/Iidy/Cfn/GlobalConfig.hs
pages <- runConduit $ Amazonka.paginate awsEnv req .| CL.consume
let params = concatMap (fromMaybe [] . (.parameters)) pages
```
([src/Iidy/Cfn/GlobalConfig.hs:113-114](src/Iidy/Cfn/GlobalConfig.hs:113))

```haskell
-- src/Iidy/Yaml/Imports/Loaders/SsmPath.hs
pages <- runConduit $ Amazonka.paginate awsEnv req .| CL.consume
let params = concatMap (fromMaybe [] . (.parameters)) pages
```
([src/Iidy/Yaml/Imports/Loaders/SsmPath.hs:75-76](src/Iidy/Yaml/Imports/Loaders/SsmPath.hs:75))

**3) Output pipeline drift reduced but still not fully eliminated**
```haskell
case shellType of
  ShellBash -> putStrLn bashCompletionScript
  ShellZsh  -> putStrLn zshCompletionScript
  ShellFish -> putStrLn fishCompletionScript
```
([app/Main.hs:322-325](app/Main.hs:322), [docs/dev/adr/001-output-pipeline.md:44-45](docs/dev/adr/001-output-pipeline.md:44))

**4) `GlobalConfig` tests improved but still mostly helper-level rather than live fetch path**
```haskell
import Iidy.Cfn.GlobalConfig (applyParams)
...
sa' <- applyParams sa params
```
([test/Test/GlobalConfigTest.hs:17](test/Test/GlobalConfigTest.hs:17), [test/Test/GlobalConfigTest.hs:158-209](test/Test/GlobalConfigTest.hs:158))

## D. Risk Register
| # | Risk | Severity | Likelihood | Suggested Mitigation |
|---|---|---|---|---|
| 1 | Cross-GHC compatibility issues can still surface late in rapid implementation cycles (recent `foldl'` incident) | Medium | Medium | Add explicit multi-GHC CI jobs and keep compatibility rules codified in standards docs. |
| 2 | `GlobalConfig` catches all exceptions silently; real misconfiguration can be hidden | Medium | Medium | Keep non-fatal behavior but emit structured debug/warn signal when global config load fails. |
| 3 | `GlobalConfig` tests still do not exercise live fetch path via `applyGlobalConfiguration` | Medium | Medium | Add an integration-style test path (or injectable fetch layer) for `applyGlobalConfiguration`, not only `applyParams`. |
| 4 | HTTP security tests do not verify live timeout/cutoff behavior end-to-end | Medium | Medium | Add local test server scenarios that enforce timeout and oversized streaming responses. |
| 5 | Output pipeline ADR drift remains for completion path (`putStrLn`) | Low | Medium | Route completion through output dispatch or formally carve out/document this exception in ADR. |
| 6 | Import manifest/cycle-record machinery appears underused in traversal flow | Medium | Medium | Add traversal instrumentation/tests or simplify/remove dead tracking paths. |
| 7 | Docs/test metrics drift quickly under rapid change (docs still cite 851 vs latest successful 995) | Low | High | Generate metrics automatically and validate doc freshness in CI. |
| 8 | CI matrix remains single-OS and lacks explicit compiler-version coverage | Medium | Medium | Add macOS job and explicit compiler-version checks so compatibility issues are caught before merge. |
| 9 | CI/build has no benchmark/perf gate | Low | Medium | Add lightweight perf smoke checks for hot-path commands/loaders. |
| 10 | Single-author AI provenance raises latent semantic bug risk in custom engines | Medium | Medium | Add external differential/fuzz testing against reference libraries/spec suites for JMESPath/Handlebars/Schema. |

## E. Top Strengths
1. Rapid closure of high-impact findings in tightly scoped commits with auditable handoffs across three dense waves on 2026-03-01.
2. `TemplateLoader` now has direct integration tests for URL passthrough, render flows, and key failure paths ([test/Test/TemplateLoaderTest.hs:27-230](test/Test/TemplateLoaderTest.hs:27)).
3. Global SSM configuration path is now implemented and wired into CFN execution ([src/Iidy/Cfn/GlobalConfig.hs:48-56](src/Iidy/Cfn/GlobalConfig.hs:48), [app/Main.hs:355-359](app/Main.hs:355)).
4. SSM path/global config loaders now paginate correctly, eliminating silent truncation at >10 parameters ([src/Iidy/Yaml/Imports/Loaders/SsmPath.hs:67-79](src/Iidy/Yaml/Imports/Loaders/SsmPath.hs:67), [src/Iidy/Cfn/GlobalConfig.hs:105-117](src/Iidy/Cfn/GlobalConfig.hs:105)).
5. Env-map resolution in stack args now fails fast on missing env and invalid types, matching Rust semantics more closely ([src/Iidy/Cfn/StackArgsLoader.hs:118-143](src/Iidy/Cfn/StackArgsLoader.hs:118), [test/Test/StackArgsLoaderTest.hs:88-156](test/Test/StackArgsLoaderTest.hs:88)).
6. Polling paths now clean up spinner threads via `finally`, reducing terminal corruption on exceptions ([app/Main.hs:169-170](app/Main.hs:169), [src/Iidy/Output/Manager.hs:35-39](src/Iidy/Output/Manager.hs:35)).
7. HTTP/S3 import safety improved materially (TLS manager, YAML parsing for HTTP `.yaml`, S3 size cap, UTF-8 decode hardening, NTP underflow guard) ([src/Iidy/Yaml/Imports/Loaders/Http.hs:25](src/Iidy/Yaml/Imports/Loaders/Http.hs:25), [src/Iidy/Yaml/Imports/Loaders/S3.hs:72-88](src/Iidy/Yaml/Imports/Loaders/S3.hs:72), [src/Iidy/Cfn/TemplateLoader.hs:161-168](src/Iidy/Cfn/TemplateLoader.hs:161), [src/Iidy/Aws/Timing.hs:119-130](src/Iidy/Aws/Timing.hs:119)).
8. Parser compatibility break on GHC 9.6 was fixed quickly and codified as a durable coding standard ([src/Iidy/Yaml/Parser.hs:9](src/Iidy/Yaml/Parser.hs:9), [CLAUDE.md:13](CLAUDE.md:13)).

## F. Prioritized Recommendations
1. **High**: Expand CI matrix coverage beyond Linux and add explicit multi-GHC jobs to catch compatibility issues earlier in the dev loop.
2. **High**: Add integration-level coverage for `applyGlobalConfiguration` fetch behavior (not only `applyParams`) and verify error/reporting semantics.
3. **High**: Add HTTP loader behavior tests with local server fixtures for timeout and streaming cutoff enforcement.
4. **Medium**: Finish output-pipeline ADR alignment for completion output (or document it as an explicit exception).
5. **Medium**: Add targeted tests (or simplification) for import manifest/cycle-record tracking paths.
6. **Medium**: Add automated doc-metric refresh/checks so docs stay aligned with rapidly changing test/module counts.
7. **Medium**: Add lightweight perf smoke checks for loader-heavy paths.
8. **Medium**: Keep custom-engine risk bounded with differential tests against reference implementations/spec vectors.
9. **Low**: Continue decomposing oversized modules where practical (following the recent `Errors/Conversion` split pattern).

## G. Sampling Methodology (Audit Trail)

### Scope handling
- This was a **risk-based comprehensive due diligence review**, not a literal line-by-line read of all 91 source modules and 42 test modules.
- I prioritized: core execution paths, custom implementations, security-sensitive paths, build/CI, process artifacts, and test harnesses.

### Files read/sampled
- Root/config/process:
  - `iidy-hs.cabal`
  - `CLAUDE.md`
  - `WORKPLAN.md`
  - `DIVERGENCES.md`
  - `README.md`
  - `.gitignore`
  - `progress.log`
  - `Makefile`
  - `flake.nix`
  - `.github/workflows/ci.yml`
  - `notes/2026-03-01-process-trust-guide.md`
  - `notes/handoffs/done/2026-03-01-template-loader-tests.md`
  - `notes/handoffs/done/2026-03-01-global-ssm-config.md`
  - `notes/handoffs/2026-03-01-source-span-info.md`
  - `notes/handoffs/done/2026-03-01-security-review-fixes.md`
  - `notes/handoffs/done/2026-03-01-aws-api-efficiency.md`
  - `notes/handoffs/2026-03-01-fix-http-loader.md`
  - `notes/handoffs/2026-03-01-fix-performance.md`
  - `notes/handoffs/2026-03-01-fix-safety-hardening.md`
  - `notes/handoffs/2026-03-01-fix-spinner-cleanup.md`
  - `notes/handoffs/2026-03-01-fix-ssm-pagination.md`
  - `notes/handoffs/2026-03-01-fix-stackargsloader.md`
  - `scripts/check-unused-deps.sh`
- Docs:
  - `docs/SECURITY.md`
  - `docs/dev/architecture.md`
  - `docs/dev/aws-config.md`
  - `docs/dev/codebase-guide.md`
  - `docs/dev/custom-resource-templates.md`
  - `docs/dev/output-architecture.md`
  - `docs/dev/rust-compatibility.md`
  - `docs/dev/testing-guide.md`
  - `docs/dev/adr/001-output-pipeline.md`
  - `docs/dev/adr/002-ovalue-key-order.md`
  - `docs/dev/adr/003-yaml-preprocessing.md`
  - `docs/dev/adr/004-custom-implementations.md`
  - `docs/command-reference.md`
  - Additional docs queried via grep (`docs/getting-started.md`, `docs/import-types.md`, requirements docs).
- App/source (high-focus sample):
  - `app/Main.hs`
  - `src/Iidy/Render.hs`
  - `src/Iidy/GetImport.hs`
  - `src/Iidy/Cli.hs`
  - `src/Iidy/Cli/Parser.hs`
  - `src/Iidy/Cli/Help.hs`
  - `src/Iidy/Aws/Config.hs`
  - `src/Iidy/Aws/CredentialSource.hs`
  - `src/Iidy/Constants.hs`
  - `src/Iidy/Aws/Timing.hs`
  - `src/Iidy/Params/Client.hs`
  - `src/Iidy/Params/Review.hs`
  - `src/Iidy/Cfn/TemplateLoader.hs`
  - `src/Iidy/Cfn/GlobalConfig.hs`
  - `src/Iidy/Cfn/StackArgsLoader.hs`
  - `src/Iidy/Cfn/RequestBuilder.hs`
  - `src/Iidy/Cfn/StackOperations.hs`
  - `src/Iidy/Cfn/Context.hs`
  - `src/Iidy/Cfn/Operations/TemplateApproval.hs`
  - `src/Iidy/Cfn/Operations/DescribeStackDrift.hs`
  - `src/Iidy/Cfn/Operations/CreateOrUpdate.hs`
  - `src/Iidy/Cfn/Operations/UpdateStack.hs`
  - `src/Iidy/Cfn/Operations/Changeset.hs`
  - `src/Iidy/Cfn/Operations/DescribeStack.hs`
  - `src/Iidy/Cfn/Operations/CreateStack.hs`
  - `src/Iidy/Cfn/Operations/DeleteStack.hs`
  - `src/Iidy/Yaml/Engine.hs`
  - `src/Iidy/Yaml/Parser.hs`
  - `src/Iidy/Yaml/Emitter.hs`
  - `src/Iidy/Yaml/OValue.hs`
  - `src/Iidy/Yaml/JMESPath.hs`
  - `src/Iidy/Yaml/Handlebars/Engine.hs`
  - `src/Iidy/Yaml/Handlebars/Helpers.hs`
  - `src/Iidy/Yaml/CustomResources/JsonSchema.hs`
  - `src/Iidy/Yaml/CustomResources/Params.hs`
  - `src/Iidy/Yaml/CustomResources/Expansion.hs`
  - `src/Iidy/Yaml/CustomResources/RefRewriting.hs`
  - `src/Iidy/Yaml/Resolution/Resolver.hs`
  - `src/Iidy/Yaml/Resolution/Context.hs`
  - `src/Iidy/Yaml/Imports/Types.hs`
  - `src/Iidy/Yaml/Imports/Manifest.hs`
  - `src/Iidy/Yaml/Imports/Loaders/Dispatch.hs`
  - `src/Iidy/Yaml/Imports/Loaders/File.hs`
  - `src/Iidy/Yaml/Imports/Loaders/Http.hs`
  - `src/Iidy/Yaml/Imports/Loaders/Git.hs`
  - `src/Iidy/Yaml/Imports/Loaders/Random.hs`
  - `src/Iidy/Yaml/Imports/Loaders/S3.hs`
  - `src/Iidy/Yaml/Imports/Loaders/Ssm.hs`
  - `src/Iidy/Yaml/Imports/Loaders/SsmPath.hs`
  - `src/Iidy/Yaml/Imports/Loaders/Cfn.hs`
  - `src/Iidy/Yaml/Errors/Enhanced.hs`
  - `src/Iidy/Yaml/Errors/Ids.hs`
  - `src/Iidy/Yaml/Errors/Conversion.hs`
  - `src/Iidy/Yaml/Errors/Conversion/Guidance.hs`
  - `src/Iidy/Yaml/Errors/Conversion/Location.hs`
  - `src/Iidy/Yaml/Errors/Conversion/LineSearch.hs`
  - `src/Iidy/Output/Manager.hs`
  - `src/Iidy/Output/Terminal.hs`
  - `src/Iidy/Output/Spinner.hs`
  - `src/Iidy/Output/Renderers/Interactive.hs`
  - `src/Iidy/Output/Renderers/Interactive/Sections.hs`
  - `src/Iidy/Output/Renderers/Interactive/Types.hs`
  - `src/Iidy/Output/Renderers/Json.hs`
  - `src/Iidy/Demo.hs`
  - `src/Iidy/Explain.hs`
- Tests sampled:
  - `test/Main.hs`
  - `test/Test/FixtureTest.hs`
  - `test/Test/ErrorFixtureTest.hs`
  - `test/Test/PropertyTest.hs`
  - `test/Test/JMESPathTest.hs`
  - `test/Test/HandlebarsTest.hs`
  - `test/Test/JsonSchemaTest.hs`
  - `test/Test/ImportLoaderTest.hs`
  - `test/Test/AwsLoaderTest.hs`
  - `test/Test/ResolverTest.hs`
  - `test/Test/TimingTest.hs`
  - `test/Test/SecurityControlsTest.hs`
  - `test/Test/ParamsClientTest.hs`
  - `test/Test/TemplateLoaderTest.hs`
  - `test/Test/GlobalConfigTest.hs`
  - `test/Test/ParserTest.hs`

### Searches/commands run
- Inventory/metrics:
  - `pwd && ls -la`
  - `find src app -name '*.hs' | wc -l`
  - `find test -name '*.hs' | wc -l`
  - LOC and module size commands (`wc -l` over source/test trees).
- Build/test verification runs:
  - `cabal build all`
  - `cabal test ... --test-show-details=direct`
  - Intermediate run after parser-span changes failed on GHC 9.6.7 (`src/Iidy/Yaml/Parser.hs`: missing `foldl'` import), then was fixed by commit `1f2e315`.
  - Latest HEAD run in this session: full suite pass (`All 995 tests passed`) on GHC 9.6.7.
- Recent-commit review commands:
  - `git log --oneline --decorate -n 25`
  - `git show --name-only 5990d4d 6394f96 fa767b3 7e04c3d 3726bfd fc743ef 2461a42 a98159f 81f134e 42421c7 36868fe b6745e0`
  - `git show --name-only 64c353b 68ca780 0b4fefb 9a34231 9ce83cc b21afdd caf5f83 86b012d 6e78d5b 03beb1e 0ff2446 2b7624b 9b2ea58 8c8711d`
  - `git show --stat --patch 6394f96`
  - `git show --stat --patch fa767b3`
  - `git show --stat --patch 5990d4d`
  - `git show --stat --patch 7e04c3d`
  - `git show --stat --patch 3726bfd`
  - `git show --stat --patch fc743ef`
  - `git show --stat --patch 2461a42`
  - `git show --stat --patch b6745e0`
  - `git show --stat --patch 68ca780`
  - `git show --stat --patch 2b7624b`
  - `git show --stat --patch 9b2ea58`
  - `git show --stat --patch 8c8711d`
  - `git show --name-only 6c2a7ef 3467089 ba9c610 a6c245f 3e697ad 826c295 506cb97 642c9f0`
  - `git show --stat --patch 642c9f0`
  - `git show --stat --patch 826c295`
  - `git show --stat --patch 3e697ad`
  - `git show --stat --patch a6c245f`
  - `git show --stat --patch 3467089`
  - `git show --stat --patch 6c2a7ef`
  - `git show --name-status --stat --format=fuller 60d23d6`
  - `git show --name-status --stat --format=fuller 8f06c65`
  - `git show --name-status --stat --format=fuller 778348c b8233c3 a0b1853 e00f3be 6d20b10 7a1a18f 60d0f79 b9dada0`
  - `git show --name-status --stat --format=fuller eefc7ee ada0e5b 6deb078 7ef641a`
  - `git show --stat --patch 778348c`
  - `git show --stat --patch b8233c3`
  - `git show --stat --patch a0b1853`
  - `git show --stat --patch e00f3be`
  - `git show --stat --patch 6d20b10`
  - `git show --stat --patch 7a1a18f`
  - `git show --stat --patch 6deb078`
  - `git show --stat --patch 7ef641a`
  - `git show --stat --patch 6feada6 e5e1ed7 04ca142 abc420b dff5ef9 d45ad32 1a36586 1f2e315`
  - `git log --oneline --decorate -n 20`
  - `git pull --ff-only` (attempted in sandbox; user confirmed repo was pulled)
  - `cabal test all --test-show-details=direct` (post-commit revalidation; pass)
  - `cabal build all` (latest HEAD revalidation; pass)
  - `cabal test all --test-show-details=direct` (latest HEAD revalidation; pass, 995 tests)
  - `git rev-list --count HEAD`
  - `git shortlog -sn --all | head -n 5`
  - `find src app -name '*.hs' | wc -l`
  - `find test -name '*.hs' | wc -l`
  - `wc -l src/Iidy/Yaml/Errors/Conversion.hs src/Iidy/Yaml/Resolution/Resolver.hs src/Iidy/Cfn/GlobalConfig.hs`
  - `nl -ba src/Iidy/Yaml/Parser.hs | sed -n '1,30p;186,205p'`
  - `nl -ba CLAUDE.md | sed -n '1,30p'`
  - `nl -ba docs/dev/codebase-guide.md | sed -n '1,30p'`
  - `nl -ba docs/dev/testing-guide.md | sed -n '1,30p'`
  - Cross-reference verification: `rg -n "applyGlobalConfiguration|default-notification-arn|disable-template-approval" /Users/tavis/src/iidy/src /Users/tavis/src/iidy-js/src`
- Static hygiene/security scans:
  - Grep/ripgrep for `fromJust`, `undefined`, `TODO/FIXME/HACK`, warning suppressions.
  - Grep for partial patterns (`!!`, etc.), process/network/regex usage, import security function usage.
  - Grep for dependency usage signals (`amazonka-sns`, `unliftio`, etc.).
- Test structure checks:
  - Grep for `testCase`, `testProperty`, fixture/error dynamic builders.
  - Counted dynamic fixture/error tests by filesystem and skip lists.
- Provenance checks:
  - `git rev-list --count HEAD`
  - `git shortlog -sn --all`
  - `git log --oneline -n ...`

### What I did not fully examine
- Not every line of all 91 source modules and all 42 test modules was read in full.
