# Workplan Risk Review

**Reviewer posture**: Steve McConnell (Code Complete, Software Estimation, Rapid Development)
**Date**: 2026-02-21
**Inputs**: WORKPLAN.md, ecosystem-audit.md, module-inventory.md, test-inventory.md

---

## Critical Issues (would cause project failure)

### C1. The LOC estimate is internally inconsistent and optimistically wrong

The workplan opens with "Target: ~11,000-13,000 LOC Haskell (estimated 65-75% of Rust LOC)" but the phase-by-phase rollup totals **19,000 LOC** (17,550 production + 1,450 test). The workplan itself acknowledges this contradiction in a footnote ("This is higher than the initial 15-25K estimate") but never reconciles it. The original "65-75% of Rust" estimate was the anchor, and every session estimate was calibrated to it. The actual target is **106% of Rust LOC**, not 65-75%.

McConnell's *Software Estimation* (Chapter 4) documents that anchoring bias is the most common cause of estimation failure. When the topline estimate says 11-13K but the detailed estimate says 19K, the schedule was built against the wrong number.

**Concrete impact**: The "13 sessions, 8-10 hours" schedule was computed from the wrong LOC target. If the real LOC is 19K and session throughput is constant, the schedule should be ~18-22 sessions (13-16 hours). And that is the *optimistic* case.

**Recommendation**: Strike the 11-13K headline. Replace with the 19K detailed estimate. Recompute session counts using a measured throughput from Phase 1 (see recommendation R3).

### C2. The YAML parser port is underestimated by at least 3x

The Rust YAML parser (`yaml/parsing/parser.rs`) is **2,090 LOC** and is built on top of tree-sitter-yaml. The workplan allocates **800 LOC** for chunk 2.1: "YAML parsing: HsYAML-based parser with position tracking."

This is not a 1:1 port. The Rust parser walks a tree-sitter CST and converts it into an iidy-specific AST with position tracking. HsYAML's event-based API is fundamentally different: it emits a flat stream of events (DocumentStart, MappingStart, Scalar, etc.) rather than a concrete syntax tree. Building an equivalent AST from HsYAML events requires:

1. A stack-based event consumer that reconstructs nesting (~300-500 LOC)
2. Position tracking per event, with propagation to constructed AST nodes (~200 LOC)
3. Tag extraction and validation from the event stream (~200 LOC)
4. Error recovery and diagnostic generation that currently relies on tree-sitter node structure (~400+ LOC)
5. Anchor/alias resolution with position preservation (~200 LOC)
6. The 2,090 LOC Rust parser includes a tree-sitter location finder; 444 LOC in `tree_sitter_location.rs` does tree-sitter-specific position navigation (find_child_by_key, find_yaml_node_by_path). This logic needs to be reimplemented differently.

A realistic estimate for the HsYAML-based parser with equivalent functionality is **1,500-2,000 LOC Haskell**, not 800. This is the single most architecturally risky module in the entire port because every downstream module (resolution, engine, error display) depends on the shape of the AST it produces.

**Recommendation**: Triple the LOC estimate for chunk 2.1. Consider splitting it into three sub-chunks: (a) HsYAML event consumer + AST builder, (b) position tracking + error positions, (c) diagnostic generation + error recovery. Assign all three to Opus. Build a spike/prototype before committing to the HsYAML approach (see C3).

### C3. The HsYAML decision is unvalidated and may be a dead end

The workplan commits to HsYAML without a proof-of-concept, yet the ecosystem audit explicitly flags that HsYAML events provide "less granular AST structure" than tree-sitter. The risk register rates this as "Medium" impact. It should be rated **Critical**.

Here is why: iidy's error reporting is one of its key user-facing features. The Rust codebase has **2,010 LOC** of error display code (`errors/enhanced.rs` 758 LOC, `errors/display.rs` 507 LOC, `errors/ids.rs` 401 LOC, `errors/wrapper.rs` 344 LOC). This error display depends on precise source positions for:
- Underlining the exact token that caused the error
- Showing context lines around the error
- Reporting which key in a mapping triggered an issue
- Typo detection with suggestions (12 snapshot tests for typo detection alone)

HsYAML's event API provides line/column for each event, but events are at the *value* level, not the *token* level. You get the position of "the scalar started here" but not "the tag `!$typo` started at column 5 and ended at column 11." This matters for error underlining.

The workplan assumes this is "sufficient for error reporting" without testing the assumption. McConnell (Rapid Development, Chapter 6) calls this a "requirements assumption risk" -- the team assumes a technical approach satisfies requirements without validating it.

**Recommendation**: Before starting Phase 2, spend one sub-session building a spike: parse a complex iidy template with HsYAML events, reconstruct the AST, and generate error output for a variable-not-found error and a typo detection error. Compare the output quality against the Rust snapshots. If positions are insufficient, the fallback is the tree-sitter FFI approach, which adds 2-4 sessions of work.

### C4. 1,450 LOC of test code is catastrophically insufficient

The Rust codebase has **~9,775 LOC of test code** and **98 snapshot files**. The workplan allocates **1,450 LOC** for Phase 6 (tests). That is a test:production ratio of 0.08:1. The Rust codebase has a ratio of 0.59:1.

Phase 6 allocates:
- 200 LOC for test infrastructure
- 300 LOC for YAML preprocessing snapshots
- 200 LOC for output renderer snapshots
- 150 LOC for error display snapshots
- 200 LOC for property-based tests
- 300 LOC for integration tests

The Rust codebase has:
- 675 LOC of parser unit tests alone
- 405 LOC of diagnostic tests alone
- 482 LOC of property-based tests alone
- 495 LOC of handlebars tests alone
- 429 LOC of fixture tests alone
- 380 LOC of test data generation alone

The workplan is planning to port 17,550 LOC of production code with fewer tests than the Rust codebase uses for a single subsystem. This is not a test plan; it is a test placeholder.

More critically, the workplan defers all testing to Phase 6, after all production code is written. McConnell (*Code Complete*, Chapter 22) is emphatic that deferred testing leads to "undetected defects that are 10-100x more expensive to fix at integration time." The stage gates claim to require tests, but the test LOC is not budgeted in Phases 2-5.

**Recommendation**:
1. Budget at least 5,000 LOC of test code (bringing the ratio closer to 0.30:1).
2. Distribute test code into each phase. Each chunk should include its own tests.
3. Port the 98 snapshot files in the phase where their corresponding production code is written, not in Phase 6.
4. Revise session estimates to account for the additional test LOC.

---

## High-Risk Items (likely to cause significant delay)

### H1. amazonka 2.0 lens ergonomics will blow out Phase 4 estimates

The workplan acknowledges that "Haskell's terser syntax is offset by more explicit type signatures and the verbose amazonka lens API" but does not adjust for it. Let me be specific about what amazonka 2.0 code looks like.

In Rust (aws-sdk-rust):
```rust
let resp = client.describe_stacks()
    .stack_name("my-stack")
    .send()
    .await?;
let stacks = resp.stacks().unwrap_or_default();
```

In Haskell (amazonka 2.0):
```haskell
resp <- send env (newDescribeStacks & describeStacks_stackName ?~ "my-stack")
let stacks = resp ^. describeStacksResponse_stacks & fromMaybe []
```

Every field access is a lens operation. Every request construction uses lens setters. Every response destructuring uses lens getters. The `aws_conversion.rs` module alone is **906 LOC** of type conversions, and every line of it will be 1.5-2x longer in Haskell due to lens syntax.

Phase 4 estimates 4,450 LOC across 15 chunks. The actual LOC will be closer to **6,000-7,000** because:
- Request builder (chunk 4.3, estimated 350 LOC) needs lens-heavy construction for every CFN API call
- aws_conversion (chunk 3.7, estimated 500 LOC) is pure type mapping through lenses
- Every CFN operation module (4.7-4.15) touches amazonka types

Additionally, amazonka error handling is different from aws-sdk-rust. Rust uses typed error enums; amazonka uses `Error` from `Amazonka.Core` which requires pattern matching on service-specific error codes as `Text`. This is less ergonomic and error-prone.

**Recommendation**: Add a 50% buffer to all Phase 4 LOC estimates. Budget one sub-session specifically for learning/prototyping the amazonka 2.0 API patterns before starting the CFN operations.

### H2. The interactive renderer is the hardest module and is planned as one chunk

Chunk 3.5 estimates the interactive renderer at 1,500 LOC (down from 2,438 LOC Rust). This is the most complex single module in the entire codebase. It handles:
- Multi-line formatted output with precise column alignment
- ANSI color codes embedded in strings that affect width calculation
- Status icons (Unicode), padding, truncation
- Real-time event streaming with spinner overlays
- 130-character-width pixel-perfect output matching iidy-js

This is not one chunk of work. The pixel-perfect requirement means every formatting decision must match the existing output. The workplan's own Gate 3 requires "Interactive renderer pixel-perfect test passes (130-char width)." Achieving pixel-perfect output in a different language, with different string handling (Haskell `Text` vs Rust `String`), different Unicode width calculations, and different ANSI escape handling is a multi-iteration process.

McConnell (*Rapid Development*, Chapter 5) documents that "pixel-perfect" requirements are among the highest-risk types because they are difficult to test incrementally and failure is binary.

**Recommendation**: Split chunk 3.5 into at least 4 sub-chunks:
1. Core rendering functions (column layout, padding, truncation)
2. ANSI-aware string width calculation + color application
3. Stack event/resource rendering (the bulk of the output)
4. Pixel-perfect comparison harness + iterative fixing

Budget 2,500-3,000 LOC, not 1,500. This is likely a 2-session module, not a fraction of one session.

### H3. JMESPath implementation estimate is optimistic

The workplan estimates 600 LOC for a "minimal JMESPath evaluator." The Rust codebase only has 86 LOC in `jmespath.rs` because it delegates to the `jmespath` crate, which is a full implementation. But the Haskell port must implement JMESPath from scratch.

The JMESPath specification (https://jmespath.org/specification.html) defines:
- Field expressions, sub-expressions, index expressions
- Array projections, object projections, flatten projections
- Filter expressions with comparators
- Pipe expressions
- Multi-select lists and hashes
- Function calls (20+ built-in functions)
- Literal expressions

A conformant implementation is typically **1,500-2,500 LOC** (the Python reference implementation is ~2,000 LOC). Even a "minimal" implementation covering iidy's actual usage patterns needs:
- A lexer (~200 LOC)
- A parser (~300 LOC)
- An evaluator (~400 LOC)
- Built-in functions (~200 LOC)
- Tests (~300 LOC)

That is **~1,400 LOC minimum**, not 600. And "minimal" implementations have a way of becoming full implementations once you discover edge cases in user templates.

The ecosystem audit suggests porting `jamespath-hs` from GitHub. This is the better approach, but it has risks: the library has 3 stars, is not on Hackage, and may not compile with current GHC. Evaluating and fixing it could take as long as writing a new implementation.

**Recommendation**: Budget 1,200-1,500 LOC. Evaluate `jamespath-hs` as the first task in Phase 2 so you know early whether it is usable. If not, the fallback is a from-scratch implementation that should be its own session.

### H4. The resolution context + tag resolver totals 3,733 LOC in Rust and is underestimated

The workplan estimates:
- Chunk 2.3: Resolution context, 500 LOC (Rust: 1,129 LOC)
- Chunk 2.4: Tag resolver, 1,200 LOC (Rust: 2,604 LOC)
- Total: 1,700 LOC estimate vs 3,733 LOC Rust

A 46% reduction from Rust to Haskell for the resolver is plausible only if Haskell's pattern matching and ADTs eliminate significant boilerplate. But the resolver is not boilerplate -- it is complex recursive logic with context threading, async imports, error accumulation, and variable tracking. The `TagContext` alone has environment values, credential sources, current location, and variable metadata.

The Rust resolver supports at least 15 custom tags, each with its own resolution logic. In Haskell, you get terser pattern matching but you pay for explicit monad transformer threading, and you need `ExceptT` or similar for error accumulation within the resolver.

Realistic estimate: **2,200-2,800 LOC** for resolution context + tag resolver combined.

**Recommendation**: Increase chunk 2.3 to 700 LOC and chunk 2.4 to 1,600 LOC. These chunks should remain Opus-assigned, as they are the architectural spine of the YAML engine.

### H5. No plan for running the Rust binary alongside the Haskell port for comparison

Gate 6 says "All 98 Rust snapshot files produce identical output from Haskell." Gate 3 says "pixel-perfect snapshot tests pass." But the workplan contains no infrastructure for running the Rust binary and comparing output. The snapshots are static files, but what about:
- Dynamic output (timestamps, account IDs, region-specific data)?
- Terminal width-dependent formatting?
- Color output that depends on terminal capabilities?

The workplan assumes snapshot files are sufficient, but snapshot files are frozen at a point in time. If the Rust binary has been updated since the snapshots were captured, the Haskell port will be chasing a moving target.

**Recommendation**: Add a chunk (0.5 session) in Phase 1 to:
1. Build the Rust binary and capture fresh snapshots.
2. Set up a comparison harness that runs both binaries on the same input and diffs their output.
3. Use this harness throughout development, not just at Gate 6.

---

## Medium-Risk Items (may cause delay)

### M1. cabal dependency resolution with amazonka + HsYAML + brick

The workplan lists `brick`, `vty`, `vty-crossplatform`, `HsYAML`, `yaml`, and 7 `amazonka-*` packages. In practice, `brick` and `amazonka` have historically been difficult to resolve together because they pin different versions of `lens` and `base`. The `HsYAML` package uses a different YAML data model than `yaml` (which wraps libyaml); having both may cause confusion.

Key decision in the workplan (section 5): "No brick/ratatui TUI. The interactive renderer is not actually a TUI app -- it's a sequential ANSI output stream." This is good -- it eliminates brick from runtime deps. But brick is still listed in the dependency list. If it is not needed, remove it. Every unnecessary dependency is a potential solver conflict.

**Recommendation**: Remove `brick`, `vty`, `vty-crossplatform` from build-depends if the interactive renderer will use `ansi-terminal` + `System.IO`. Pin `amazonka` packages to the same revision. Run `cabal build` dependency resolution in Phase 1 before writing any code.

### M2. HsYAML + yaml (libyaml) dual dependency

The dependency list includes both `HsYAML` and `yaml`. These are two different YAML libraries with different data models:
- `HsYAML`: Pure Haskell, YAML 1.2, event-based API
- `yaml`: C FFI to libyaml, YAML 1.1, aeson-integrated

The Rust codebase uses both `yaml-rust` and `serde_yaml` for different purposes, so there may be a legitimate need. But having two YAML libraries creates confusion about which one to use where, and increases the dependency footprint.

**Recommendation**: Clarify which library is used for what. If `yaml` is only needed for quick aeson-based YAML parsing (e.g., loading config files), document this explicitly. If HsYAML can serve both purposes, drop `yaml`.

### M3. Custom resources subsystem is larger than estimated

The workplan allocates chunk 2.9 at 500 LOC for "Custom resources: params, expansion, ref_rewriting." The Rust source has:
- `custom_resources/params.rs`: 745 LOC
- `custom_resources/expansion.rs`: 454 LOC
- `custom_resources/ref_rewriting.rs`: 421 LOC
- Total: **1,620 LOC Rust**

Even at a generous 40% Haskell reduction, that is ~970 LOC, not 500. Custom resources involve JSON Schema validation (which requires the minimal validator from Gap #1), parameter type checking, template expansion with variable substitution, and reference rewriting -- all interconnected.

**Recommendation**: Increase chunk 2.9 estimate to 800-1,000 LOC. Consider splitting into two sub-chunks: params/validation and expansion/rewriting.

### M4. Handlebars helper coverage is uncertain

The workplan says "Port helpers manually (~300 LOC)" and the ecosystem audit says "Audit shows iidy uses `{{variable}}` + custom helpers." But the Rust handlebars subsystem totals **773 LOC** across:
- `encoding.rs`: 197 LOC
- `object_access.rs`: 78 LOC
- `serialization.rs`: 63 LOC
- `string_case.rs`: 196 LOC
- `string_manip.rs`: 239 LOC

Even excluding the engine (93 LOC), the helpers alone are 773 LOC Rust. The workplan estimates 400 LOC total for chunk 2.5 (Handlebars/Mustache engine + helpers). This is about half of the Rust helper code alone.

Additionally, the `mustache` package provides Mustache syntax but iidy uses Handlebars features beyond Mustache: custom helpers with arguments, encoding functions, and nested object access. The workplan has not audited which Handlebars features are actually used, despite the ecosystem audit recommending "Audit first, then decide."

**Recommendation**: Perform the Handlebars audit before estimating. Increase chunk 2.5 to 600-800 LOC. Port each helper category as a testable unit.

### M5. Lazy evaluation risks in the YAML engine

The two-phase YAML engine processes potentially large templates with deep nesting. In Haskell, lazy evaluation can cause:

1. **Thunk accumulation in the resolver**: The tag resolver recursively processes AST nodes. If intermediate `Value`s are built lazily, a deeply nested template could accumulate millions of thunks before any are forced. This manifests as a stack overflow or OOM during Phase 2 resolution.

2. **Space leaks in the import system**: Import values are stored in `HashMap<String, Value>`. If these Values are lazy and contain references to the original YAML source text, the entire source text will be retained in memory even after parsing completes. This is a classic Haskell space leak.

3. **Strict vs lazy ByteString/Text confusion**: amazonka uses lazy ByteString internally; aeson uses strict Text; HsYAML may use either. Converting between lazy and strict at module boundaries is error-prone and can cause unexpected memory behavior.

The workplan's monad stack is `ReaderT AppEnv IO`, which is fine, but it does not address strictness of the data flowing through it.

**Recommendation**: Add explicit strictness annotations (`!`) on all fields in core data types (AST nodes, TagContext, EnvValues, OutputData). Use `BangPatterns` and `StrictData` language extensions project-wide. Budget time in Phase 6 for profiling with `+RTS -hc` to detect space leaks. Add a memory usage gate (the 512MB gate in Gate 6 is good, but test it with large templates, not just typical ones).

### M6. The "session" unit is undefined and uncalibrated

The workplan estimates "13 sessions, 8-10 hours wall clock." This implies ~40-46 minutes per session. But a "session" is never defined. Is it one Claude interaction? One human work session? The throughput assumption (LOC per session) is never stated and never measured.

McConnell (*Software Estimation*, Chapter 10) calls this the "undefined unit" anti-pattern: estimates in fictional units cannot be validated, tracked, or recalibrated.

**Recommendation**: After Phase 1 completes, measure actual LOC produced, time spent, and rework rate. Use this to recalibrate all subsequent phase estimates. If Phase 1 (1,600 LOC) takes 1.5 sessions instead of 1, apply the 1.5x factor across the board.

### M7. Sonnet delegation risks for non-mechanical work

Several chunks are assigned to Sonnet that are not purely mechanical:
- Chunk 4.2: Stack args loader (400 LOC) -- involves YAML preprocessing pipeline integration
- Chunk 4.3: Request builder (350 LOC) -- involves amazonka lens API
- Chunk 4.4: Template loader (250 LOC) -- involves async preprocessing + S3 upload
- Chunk 4.12: Import loaders requiring AWS (600 LOC) -- cfn.rs alone is 1,113 LOC in Rust

The delegation strategy assumes Sonnet can handle these after "Opus designs interfaces." But the interface is only part of the problem. These chunks require understanding the amazonka API, async error handling, and the preprocessing pipeline. A Sonnet agent that has only seen the interface definition, not the full context, will produce code that compiles but does not correctly handle edge cases.

**Recommendation**: Reassign chunks 4.2, 4.3, 4.4, and 4.12 to Opus, or at minimum ensure Sonnet has access to the Rust source for these modules as reference. Budget for Opus review of all Sonnet-produced AWS integration code.

---

## Recommendations (specific changes to the workplan)

### R1. Fix the headline LOC estimate
Replace "~11,000-13,000 LOC Haskell (estimated 65-75% of Rust LOC)" with "~19,000-22,000 LOC Haskell (including tests), estimated 115-130% of Rust LOC." The Haskell port will not be shorter than the Rust original for this codebase, because amazonka lens verbosity and explicit type signatures offset Haskell's terser syntax.

### R2. Add a Phase 0: Feasibility Spikes (1 session)
Before starting Phase 1, validate the three riskiest assumptions:
1. **HsYAML spike**: Parse a complex iidy template, reconstruct AST, generate error with position info. Validate that HsYAML event positions are sufficient for error underlining.
2. **amazonka spike**: Write a minimal describe-stacks call with amazonka 2.0. Verify the lens API patterns, error handling, and credential loading.
3. **Dependency resolution spike**: Create the cabal file with all planned dependencies. Run `cabal build` to verify the solver can find a consistent plan.

This phase costs 1 session but saves 3-5 sessions of rework if any assumption proves wrong.

### R3. Calibrate after Phase 1
Measure actual throughput in Phase 1 (LOC/session, rework rate, time per chunk). Use this to recalibrate all subsequent estimates. Do not trust the current estimates until they are calibrated against actual data. McConnell (*Software Estimation*, Chapter 12) shows that estimates calibrated against historical data are 3-4x more accurate than uncalibrated estimates.

### R4. Distribute tests into production phases
Move test LOC from Phase 6 into Phases 2-5. Each chunk should produce its own unit tests. Snapshot files should be ported when their corresponding production code is written. This increases per-phase estimates by ~30% but dramatically reduces integration risk.

Revised test budget:
- Phase 2: +1,500 LOC (parser tests, resolver tests, handlebars tests, snapshot ports)
- Phase 3: +800 LOC (output snapshot tests, pixel-perfect tests)
- Phase 4: +1,200 LOC (AWS integration tests, mock tests)
- Phase 5: +500 LOC (CLI tests, command tests)
- Phase 6: +1,000 LOC (remaining integration, property-based, profiling)
- Total: ~5,000 LOC test code

### R5. Resequence Phase 4 to start with a read-only operation
The workplan already has chunk 4.7 (describe-stack + list-stacks) as "good first test," but it depends on chunks 4.1-4.6. This is correct dependency ordering. However, move chunk 4.1 (amazonka client setup) to immediately after the Phase 0 spike (R2), so amazonka integration issues surface early.

### R6. Add explicit fallback decisions with deadlines
For each risk item, specify when the decision must be made and what the fallback is:
- HsYAML: If the spike (R2) fails, switch to tree-sitter FFI. Decision deadline: end of Phase 0.
- JMESPath: If `jamespath-hs` evaluation fails, budget 1,500 LOC from-scratch implementation. Decision deadline: start of Phase 2.
- Handlebars: If audit shows complex helper usage, budget 800 LOC for custom helpers. Decision deadline: start of chunk 2.5.

### R7. Remove unused dependencies from the cabal file
Remove `brick`, `vty`, `vty-crossplatform` (architectural decision #5 says they are not needed). Remove either `HsYAML` or `yaml` after clarifying which is the primary YAML library. Remove `req` or `http-conduit` (pick one HTTP library). Every removed dependency reduces the solver constraint space and build time.

### R8. Revised total estimate

| Phase | Workplan LOC | Revised LOC | Revised Sessions |
|-------|-------------|-------------|-----------------|
| Phase 0 (spikes) | -- | 200 | 1 |
| Phase 1 (types) | 1,600 | 1,600 | 1 |
| Phase 2 (YAML) | 6,050 | 8,500 | 6-7 |
| Phase 3 (output) | 2,930 | 4,000 | 3-4 |
| Phase 4 (AWS/CFN) | 4,450 | 6,500 | 5-6 |
| Phase 5 (CLI) | 2,500 | 2,800 | 2-3 |
| Phase 6 (tests + polish) | 1,450 | 1,500 | 1-2 |
| **Total** | **18,980** | **25,100** | **19-24** |

Wall clock at ~45 min/session: **14-18 hours** (vs workplan's 8-10 hours).

This revised estimate applies a ~1.3x factor to production LOC (based on the detailed analysis of underestimates above) and adds ~5,000 LOC of distributed test code. By McConnell's cone of uncertainty, the actual effort at this stage of planning is likely in the range of 0.67x to 1.5x of this revised estimate, yielding a **10-27 hour** confidence interval.

The workplan's 8-10 hour estimate falls below the bottom of the cone of uncertainty. It is not a plausible outcome.
