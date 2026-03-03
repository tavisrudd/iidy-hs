# Workplan Agent Resilience Analysis

**Date**: 2026-02-21
**Workplan**: `/home/tavis/src/iidy-hs/WORKPLAN.md`
**Constraint environment**: Claude Max (5hr/week rolling), 28GB RAM (18GB used), 24 cores, NixOS, no sudo, no home-manager, git --no-gpg-sign required

---

## Token Budget Analysis

### Per-session token math

A Claude Max Opus session has ~200K tokens of context window. A typical implementation session involves:

| Activity | Tokens (est.) |
|----------|--------------|
| System prompt + CLAUDE.md + tool context | ~5K |
| Reading WORKPLAN.md + handoff state | ~10K |
| Reading Rust source modules (reference material) | variable |
| Reading previously-written Haskell code (for integration) | variable |
| Agent reasoning + planning | ~20K per major decision |
| Generated code output (Haskell) | ~3-5 tokens/LOC |
| Build output (cabal errors, diagnostics) | ~5-15K per build cycle |
| Iterative fix-compile-fix loops | ~10-30K per stuck issue |

**Key formula**: For a session producing N LOC of Haskell while reading M LOC of Rust reference, the context consumption is roughly:
- Fixed overhead: ~15K
- Reference reading: M * 4 tokens/line (Rust is verbose)
- Code generation: N * 8 tokens/line (generation is more expensive than reading due to reasoning)
- Build iterations: ~15K per compile-fix cycle (assume 3-5 cycles per session)
- Total: ~15K + 4M + 8N + 60K

### Session-by-session budget

| Session | Rust LOC to read | Haskell LOC to write | Est. context used | Risk |
|---------|-----------------|---------------------|-------------------|------|
| 1 (Phase 1: skeleton + types) | ~2,400 (cli.rs, data.rs, ast.rs, status.rs) | ~1,600 | ~100K | LOW - mechanical type translation |
| 2 (Phase 2: 2.1-2.4: parser + resolver start) | ~5,800 (parser.rs 2090 + resolver.rs 2604 + context.rs 1129) | ~2,500 | **~180K** | **HIGH** - resolver.rs alone is 2,604 LOC to read AND understand |
| 3 (Phase 2: 2.5-2.8: handlebars + imports) | ~1,200 (handlebars, import loaders) | ~1,350 | ~90K | LOW |
| 4 (Phase 2: 2.9-2.12: custom resources + emitter + engine) | ~2,700 (expansion, params, ref_rewriting, emitter, engine) | ~1,850 | ~120K | MEDIUM |
| 5 (Phase 2 gate validation) | ~0 new reading, running tests | ~200 (test glue) | ~60K | LOW |
| 6 (Phase 3: all output) | ~4,400 (interactive.rs 2438 + json.rs 527 + color/theme/terminal ~770) | ~2,930 | **~170K** | **HIGH** - interactive.rs is 2,438 LOC of pixel-precise rendering |
| 7 (Phase 4: 4.1-4.6: AWS core) | ~2,500 (aws/mod.rs, credential_source.rs, cfn/mod.rs, stack_args.rs) | ~2,050 | ~130K | MEDIUM - amazonka API unfamiliarity |
| 8 (Phase 4: 4.7-4.12: CFN operations) | ~2,900 (individual operation modules + changeset_operations.rs 630 + cfn.rs imports) | ~2,100 | ~130K | MEDIUM |
| 9 (Phase 4: 4.13-4.15 + gate) | ~500 | ~450 | ~50K | LOW |
| 10 (Phase 5: 5.1-5.6: CLI) | ~1,400 (cli.rs 900, main.rs 306, params/* ~350) | ~1,150 | ~80K | LOW |
| 11 (Phase 5: 5.7-5.11) | ~1,800 (convert_stack, demo.rs 610, http/git loaders) | ~1,350 | ~100K | MEDIUM - demo.rs has PTY concerns |
| 12 (Phase 6: 6.1-6.5: test infra) | ~2,000 (reading Rust test files for patterns) | ~900 | ~100K | LOW |
| 13 (Phase 6: 6.6-6.8: final) | ~1,000 | ~600 | ~80K | LOW |

### Critical context window risks

**Session 2 is the highest risk.** It attempts to read and translate the three largest, most complex modules:
- `resolver.rs` (2,604 LOC) - deeply recursive, many tag types, context-dependent
- `parser.rs` (2,090 LOC) - tree-sitter specific, must be redesigned for HsYAML
- `context.rs` (1,129 LOC) - resolution context, variable tracking

Combined reading of ~5,800 LOC of complex Rust plus generating ~2,500 LOC of Haskell, plus iterative compilation, will likely exceed 200K tokens.

**Mitigation**: Split Session 2 into two sessions:
- **2a**: Parser only (2.1) - read parser.rs + ast.rs, design HsYAML-based parser, implement, compile
- **2b**: Resolver + context (2.2-2.4) - read resolver.rs + context.rs + detection.rs, implement all three

**Session 6 is the second-highest risk.** The interactive renderer (2,438 LOC) is pixel-precise rendering code that must match iidy-js output exactly. Reading this + generating the Haskell equivalent + iterating on ANSI output correctness will consume significant context.

**Mitigation**: Split Session 6:
- **6a**: Renderer typeclass + color/theme/terminal/spinner (3.1-3.4) - simpler modules
- **6b**: Interactive renderer (3.5) alone - the 2,438 LOC monster
- **6c**: JSON renderer + AWS conversion (3.6-3.7)

### Revised session count

With the splits: 13 sessions becomes **16 sessions** (add 2a/2b split, 6a/6b/6c split).

### 5hr/week token budget

The Claude Max 5hr/week is the binding constraint. Key questions:

1. **How many sessions per 5hr window?** Each session runs ~30-60 minutes wall clock. A well-pipelined session (agent reads, writes, compiles, iterates) consumes roughly 30-45 minutes of active model time per session. Estimated 2-3 sessions per week at the margins, possibly 4 if sessions are short.

2. **Total project timeline**: 16 sessions / ~3 sessions per week = **~5-6 weeks elapsed time**. This is realistic but tight. If sessions run longer (stuck on compilation, dependency resolution), it could stretch to 7-8 weeks.

3. **Budget risk**: A single session stuck in a compile-fix loop (e.g., amazonka type errors, GHC version conflicts) can burn 30+ minutes of budget producing no useful output. The project needs at least 3 "clean" weeks to complete.

4. **Recommendation**: Front-load the riskiest work (bootstrapping, parser, resolver) into the earliest weeks. If those go well, the remaining work is increasingly mechanical and faster. If they don't, you learn early and can adjust scope.

---

## Context Window Risk Map

### Red (likely to exceed or approach 200K limit)

| Session | Content load | Risk factor |
|---------|-------------|-------------|
| 2 (original plan) | 5,800 LOC Rust + 2,500 LOC Haskell generation + compile iterations | Three largest modules in one session |

### Yellow (might approach limit with compile churn)

| Session | Content load | Risk factor |
|---------|-------------|-------------|
| 6 (original plan) | 4,400 LOC Rust + 2,930 LOC generation + pixel-perfect iteration | Interactive renderer requires many compile-test-adjust cycles |
| 7 (AWS core) | 2,500 LOC Rust + amazonka API exploration + compile iterations | amazonka's lens-heavy API requires trial-and-error exploration |
| 4 (engine + emitter + custom resources) | 2,700 LOC across 5 modules + integration with prior work | Must hold the full YAML pipeline in context |

### Green (comfortably within limits)

All other sessions. Types-only sessions, mechanical translations, and test-writing sessions are well within 200K.

### Sub-agent context window risks

Sub-agents (Sonnet) have their own context windows. Tasks delegated to Sonnet must include:
1. The relevant Rust source file(s)
2. The Haskell module interfaces they need to conform to
3. Build/test commands

If a sub-agent task requires reading more than ~3,000 LOC of reference material plus generating >1,000 LOC, it should be split. The following Sonnet-delegated chunks risk this:

- **Chunk 1.5** (CLI types, 400 LOC generation from cli.rs 900 LOC) - fine
- **Chunk 4.11** (changeset operations, from changeset_operations.rs 630 LOC) - fine
- **Chunk 5.7** (convert-stack-to-iidy, from convert_stack_to_iidy.rs 827 LOC + 500 LOC generation) - borderline

---

## Stuck State Catalog (with mitigations)

### S1: Nix flake bootstrap failure

**Description**: `nix develop` fails due to GHC version conflicts, missing Haskell packages in nixpkgs, or amazonka not building with the chosen GHC version.

**Likelihood**: HIGH. This is the #1 failure mode for new Haskell projects. amazonka 2.0 requires specific GHC versions and has known issues with GHC 9.6+. The nixpkgs Haskell package set is a snapshot and may not have all needed packages at compatible versions.

**Detection**: `nix develop` or `nix build` fails with dependency resolution errors.

**Mitigations**:
1. **Pin a known-good GHC version.** GHC 9.4.8 is the safest bet for amazonka 2.0 compatibility. GHC 9.6 may work but has more breakage risk. Avoid GHC 9.8+ for now.
2. **Use `haskellPackages.override` in flake.nix** to pin specific package versions if the nixpkgs snapshot has version conflicts.
3. **Test the flake with JUST amazonka + aeson + HsYAML before adding all dependencies.** If these three resolve, everything else likely will.
4. **Fallback: `cabal.project` freeze file.** Generate a freeze file from a working `cabal build` and commit it. This removes solver nondeterminism.
5. **Agent instruction**: If `nix develop` fails 3 times with different GHC versions, STOP and write a note. Don't thrash.

### S2: Cabal dependency resolution failure

**Description**: `cabal build` fails because the solver can't find a compatible set of package versions, particularly with the large amazonka dependency tree.

**Likelihood**: MEDIUM-HIGH. The amazonka family pulls in ~200+ transitive dependencies. Version conflicts between amazonka and other packages (especially `aeson`, `http-client`, `lens`) are common.

**Detection**: `cabal build` exits with "could not resolve dependencies" or "version conflict" errors.

**Mitigations**:
1. **Add explicit version bounds in .cabal file** for all direct dependencies, not just `base`.
2. **Use `allow-newer` in cabal.project** as a targeted escape hatch: `allow-newer: amazonka:*` if needed.
3. **Separate build phases**: First get types-only modules compiling (no amazonka dep), then add amazonka in Phase 4. This avoids paying the dependency resolution cost early.
4. **Agent instruction**: If solver fails, try `cabal build --dry-run` to see the conflict, then add a constraint or `allow-newer` for the specific package. Don't blindly upgrade everything.

### S3: GHC out-of-memory during compilation

**Description**: GHC runs out of memory compiling a module, especially with amazonka (which generates enormous amounts of code per service).

**Likelihood**: HIGH given the machine state (18GB used of 28GB, 6.3GB swap already consumed). GHC compiling amazonka-cloudformation alone can use 4-6GB.

**Detection**: GHC process killed by OOM killer, or cabal reports "ghc: out of memory".

**Mitigations**:
1. **Set `jobs: 2` (not 4) in cabal.project** given current memory pressure. 4 parallel GHC processes with amazonka = potential 16-24GB peak.
2. **Add `ghc-options: -O0` in cabal.project** for development. Optimization dramatically increases compile-time memory.
3. **Add `-j2 +RTS -M4G -RTS` to cabal build invocation** to hard-cap GHC heap per process.
4. **Consider `-split-sections` for linking phase** to reduce linker memory.
5. **Agent instruction**: If OOM occurs, reduce jobs to 1, retry. If it still OOMs, the module may need to be split, or other processes need to be killed. Write a note rather than endlessly retrying.
6. **Pre-flight check**: Before each session, verify available memory with `free -h`. If available < 4GB, warn the user that compilation may OOM.

### S4: C library missing for tree-sitter FFI

**Description**: The workplan says "use HsYAML event API with positions instead" of tree-sitter, but if the agent (or a future revision) tries tree-sitter FFI, it needs the C tree-sitter library and tree-sitter-yaml grammar compiled and available.

**Likelihood**: LOW (workplan chose HsYAML), but worth cataloging.

**Detection**: Linker error: "undefined reference to `tree_sitter_yaml`".

**Mitigation**: The workplan already chose HsYAML. Add an explicit note in the workplan: "Do NOT attempt tree-sitter FFI unless HsYAML proves insufficient for location tracking. If attempting tree-sitter, the C libraries must be added to the Nix flake's buildInputs."

### S5: Network failures during Hackage downloads

**Description**: `cabal update` or `cabal build` fails to download packages from Hackage.

**Likelihood**: LOW but annoying. More likely with Nix fetching from cache.nixos.org.

**Detection**: Connection timeout, HTTP 503 errors from Hackage or the Nix cache.

**Mitigations**:
1. **Nix pins prevent this for Nix-managed deps.** The flake.lock freezes all inputs.
2. **cabal.project can set a Hackage mirror** if the primary is down.
3. **Agent instruction**: If network errors occur, retry once. If persistent, check if the Nix cache is accessible (`curl -I https://cache.nixos.org`). If the issue is transient, wait 60 seconds and retry. If persistent, STOP -- this requires human intervention (VPN, network config, etc.).

### S6: Test infrastructure doesn't exist yet

**Description**: The workplan defers test infrastructure to Phase 6, but Phase 2's gate requires "snapshot output matches Rust's insta snapshots." The agent needs to compare output but has no test framework yet.

**Likelihood**: CERTAIN. This is a design flaw in the workplan.

**Detection**: Phase 2 gate check fails because there's no snapshot comparison tool.

**Mitigations**:
1. **Add a minimal snapshot comparison to Phase 2, not Phase 6.** At minimum: a script that runs `iidy-hs render <fixture>` and `diff`s against the expected output file. No need for a full golden-file framework -- just `diff`.
2. **Copy the 6 YAML test fixtures and relevant snapshot files from the Rust codebase into `test-fixtures/` during Phase 1.** This is a prerequisite for any testing.
3. **Agent instruction**: Before attempting any gate validation that requires snapshot comparison, verify that (a) the reference snapshot files exist, and (b) a comparison mechanism exists. If not, create them first.

### S7: No reference binary for snapshot comparison

**Description**: The final gate requires "All 98 Rust snapshot files produce identical output from Haskell." This requires running the Rust binary to generate reference output, or having pre-captured snapshots.

**Likelihood**: HIGH. The Rust binary (`iidy`) exists at `/home/tavis/src/iidy/` but may not be built, and many commands require AWS credentials or real stacks.

**Detection**: Agent tries to run `iidy render <file>` and either the binary doesn't exist or the command fails due to missing AWS context.

**Mitigations**:
1. **Use the existing insta snapshot files as the reference, NOT live binary output.** The snapshot files at `/home/tavis/src/iidy/tests/snapshots/*.snap` are the canonical expected output. Copy them into the Haskell project during Phase 1.
2. **For YAML preprocessing snapshots (Phase 2 gate)**: Only `render` command snapshots are needed. These don't require AWS credentials.
3. **For CloudFormation operation snapshots (Phase 4 gate)**: These DO require AWS credentials and real stacks. Either:
   - Use fixture-based test data (the Rust codebase has `output/test_data.rs` with sample data)
   - Skip live comparison and test against fixture data
   - OR require the user to provide AWS credentials in a `.env` file
4. **Agent instruction**: NEVER attempt to call real AWS APIs during testing unless explicitly configured. Use fixture data for output rendering tests.

### S8: HsYAML position tracking insufficient

**Description**: The workplan chose HsYAML over tree-sitter for YAML parsing. HsYAML provides line/column in its event stream, but iidy's error reporting uses tree-sitter for more precise AST-level position tracking (e.g., pointing to a specific key in a mapping, not just the line).

**Likelihood**: MEDIUM. The precision gap may cause snapshot mismatches in error reporting output.

**Detection**: Error display snapshot tests fail because positions are off by a few characters compared to the tree-sitter-based Rust output.

**Mitigations**:
1. **Accept minor position differences in error snapshots.** Update the expected snapshots for the Haskell version to reflect HsYAML's position granularity.
2. **Post-process HsYAML positions** to find the exact character position within a line (this is what `yaml/location.rs` does in the Rust version -- it has both `ManualLocationFinder` and `TreeSitterLocationFinder`).
3. **The Rust code already has `ManualLocationFinder` (476 LOC) as a fallback.** Port this alongside HsYAML -- it does manual position refinement using string scanning.

### S9: amazonka API shape doesn't match Rust SDK

**Description**: The amazonka Haskell API uses lenses and a different request/response structure than the Rust AWS SDK. Translating the Rust SDK patterns to amazonka may require significant rethinking, not just mechanical translation.

**Likelihood**: CERTAIN. amazonka uses `Control.Lens` for field access, `Amazonka.Send` for requests, and has different error types. The Rust code uses builder patterns and `.await` on futures.

**Detection**: The agent spends multiple compile-fix cycles trying to use amazonka in a way that doesn't match its idioms.

**Mitigations**:
1. **Agent should read amazonka documentation/examples BEFORE writing any AWS code.** At minimum, read the `amazonka` README and one example (e.g., S3 put object).
2. **Create an `Iidy.Aws.Prelude` module** that wraps common amazonka patterns (send request, extract field, handle error) in simpler functions. This isolates the lens-heavy code.
3. **Start with `describe-stack` (read-only, simple request/response)** as the first amazonka integration test. If this works, the pattern generalizes.

### S10: brick/vty not needed (architecture mismatch)

**Description**: The workplan lists `brick` and `vty` as dependencies, but Key Architectural Decision #5 says "No brick/ratatui TUI. The interactive renderer is not actually a TUI app -- it's a sequential ANSI output stream."

**Likelihood**: CERTAIN (the workplan contradicts itself).

**Detection**: Agent tries to use brick for the interactive renderer and discovers it's the wrong abstraction.

**Mitigation**: Remove `brick`, `vty`, and `vty-crossplatform` from the dependency list. The interactive renderer needs only `ansi-terminal` for color codes and `System.IO` for output. This actually simplifies the project significantly and reduces dependency weight.

### S11: git commit blocked by YubiKey GPG

**Description**: Default `git commit` may try to GPG-sign and block waiting for YubiKey tap.

**Likelihood**: HIGH if the user's `.gitconfig` has `commit.gpgsign = true`.

**Detection**: `git commit` hangs indefinitely.

**Mitigation**: **All git commits must use `--no-gpg-sign`.** Add this instruction prominently in the agent prompt. Alternatively, add to the repo's `.git/config`:
```
[commit]
    gpgsign = false
```

### S12: Sub-agent produces code that doesn't compile against current project state

**Description**: A Sonnet sub-agent generates Haskell code based on interfaces described to it, but the actual types/signatures have drifted from what the sub-agent was told.

**Likelihood**: MEDIUM-HIGH. Every sub-agent invocation is a snapshot; the project evolves.

**Detection**: Code from sub-agent fails to compile when integrated.

**Mitigations**: See "Sub-agent coordination" section below.

---

## Handoff Protocol Recommendations

### Current state: file-based WORKPLAN.md tracking

The workplan tracks session progress in a table with "Not started" status. This is necessary but insufficient.

### What's missing

1. **Build state**: Does `cabal build` currently succeed? What modules are compiled? The next session needs to know if the project is in a green state or a broken state.

2. **Dependency state**: Were any `allow-newer`, version overrides, or cabal constraints added? These won't be obvious from the code alone.

3. **Deviation log**: If the agent deviated from the workplan (split a chunk, reordered work, discovered a new issue), where is this recorded? The WORKPLAN.md table only says "Done" or "Not started."

4. **Sub-agent output locations**: If a Sonnet sub-agent wrote code to specific files, the next session needs to know which files were sub-agent-generated (and may need review/integration).

5. **Partial progress within a chunk**: If a session completes 2.1 but crashes mid-2.2, what state is 2.2 in? Is there partially-written code? Does it compile?

### Recommended handoff protocol

Add a `HANDOFF.md` file (separate from WORKPLAN.md) that gets overwritten at the end of each session:

```markdown
# Session Handoff

## Last Session
- Session ID: <uuid>
- Date: <date>
- Chunks completed: 2.1, 2.2
- Chunks in progress: 2.3 (partial -- TagContext type defined, EnvValues not started)
- Build state: GREEN (cabal build succeeds with warnings)
- Test state: 4/4 parser tests pass, no resolver tests yet

## Known Issues
- HsYAML line positions are 1-indexed, Rust tree-sitter is 0-indexed. Needs adjustment in error display.
- `allow-newer: HsYAML:base` was needed in cabal.project due to nixpkgs base version.

## Files Modified This Session
- src/Iidy/Yaml/Parser.hs (NEW, 450 LOC)
- src/Iidy/Yaml/Ast.hs (MODIFIED, added Eq instances)
- test/Yaml/ParserSpec.hs (NEW, 80 LOC)
- cabal.project (MODIFIED, added allow-newer)

## Next Session Should
1. Start by verifying `cabal build` succeeds
2. Continue with chunk 2.3 (resolution context)
3. Read resolver.rs for context before starting

## Deviations from Workplan
- Split chunk 2.1 (parser) into two compile-fix iterations. First attempt used HsYAML's ToJSON, second attempt used custom AST. Second approach works.
```

### Crash recovery

If a session crashes mid-chunk (context window exhausted, network failure, OOM):

1. **Git state is the ground truth.** The session's last commit (if any) defines the known-good state.
2. **Uncommitted changes should be stashed** by the session-starting prompt: "If there are uncommitted changes, run `git stash` and note this in HANDOFF.md."
3. **The next session reads HANDOFF.md first**, falls back to `git log` and `cabal build` output to reconstruct state.
4. **Agent instruction**: At the START of every session, before doing anything else:
   ```
   1. Read HANDOFF.md
   2. Run `git status` to check for uncommitted changes
   3. Run `cabal build` to verify build state
   4. Read WORKPLAN.md to find next chunk
   ```

---

## Commit Strategy

### Granularity

Commit after each chunk that reaches a defined quality gate:

| Gate level | When to commit | Commit message convention |
|-----------|---------------|--------------------------|
| Compiles | After types-only modules (Phase 1 chunks) | `Add <module> types (compiles, no tests)` |
| Compiles + unit tests | After logic modules (Phase 2-5 chunks) | `Implement <module> (<N> tests passing)` |
| Gate passes | After a phase gate validation | `Pass Phase N gate: <description>` |
| Integration works | After cross-module integration | `Integrate <system>: <what works>` |

### Partial compilation

**Question**: What if a chunk partially compiles but tests aren't written yet?

**Answer**: Commit anyway, but tag it clearly. It's better to have a compiling partial commit than to lose work to a session crash. Use the convention:

```
Add Yaml.Resolution.Resolver (compiles, tests pending)

Implements tag resolution for: !$, !cfn, !sub, !join, !base64.
Remaining: !importyaml, !importjson, conditional tags.
Tests deferred to chunk 2.5.
```

### What NOT to commit

- Code that doesn't compile (even with warnings). Always reach `cabal build` success.
- Generated files that belong in `.gitignore` (dist-newstyle/, *.hi, *.o).
- Cabal freeze files during development (they change constantly).

### Commit mechanics

Every `git commit` must use `--no-gpg-sign`:
```bash
git commit --no-gpg-sign -m "message"
```

---

## Sub-agent Coordination

### Structural rules to prevent conflicts

1. **One file per sub-agent.** Never have two sub-agents writing to the same file. If a module is large, the main Opus session writes the module and delegates individual functions to sub-agents as separate files, then integrates.

2. **Interface-first delegation.** Before delegating to Sonnet:
   - Write the module's type signatures (typeclass, data types, function signatures with `undefined` bodies)
   - Commit this skeleton
   - The sub-agent's prompt includes the skeleton file and says "implement the undefined functions"

3. **Sub-agent receives compilation context.** Every sub-agent prompt must include:
   - The exact module name and file path
   - All imported modules' type signatures (not full implementations)
   - The current cabal file (for dependency awareness)
   - The command to verify: `cabal build iidy-hs:lib:iidy-hs`
   - The GHC version in use

4. **Sub-agent output is always a single file.** The sub-agent returns a complete Haskell module. The main session writes it to the file and runs `cabal build`. If it doesn't compile, the main session fixes it (or re-delegates with the error message).

### Sub-agent context budget

Sonnet has a smaller effective context window for generation tasks (~100K usable). Budget:

| Sub-agent task type | Rust LOC in | Haskell LOC out | Context estimate | Viable? |
|-------------------|-------------|-----------------|-----------------|---------|
| Type definitions (1.2-1.6) | 300-900 | 150-400 | ~30K | YES |
| Import loader (2.8, 4.12) | 150-300 | 100-250 | ~20K | YES |
| CFN operation (4.7-4.9) | 100-350 | 80-300 | ~25K | YES |
| CLI definitions (5.1) | 900 | 500 | ~40K | YES |
| Color/theme (3.2-3.3) | 600 | 300 | ~30K | YES |
| Convert-stack (5.7) | 827 | 500 | ~50K | YES, but borderline |

All planned sub-agent delegations fit within Sonnet's context budget.

### Integration checklist

After receiving sub-agent output:
1. Write the file
2. `cabal build` -- if fails, fix locally (don't re-delegate for minor issues)
3. If the fix requires understanding the Rust source, fix it in the main Opus session
4. `cabal test` -- if tests exist for this module
5. Commit with note: "Implement <module> (sub-agent generated, Opus integrated)"

---

## Bootstrapping De-Risk Plan

Phase 1 (Chunk 1.1) is the highest-risk single chunk in the entire project. If the Nix flake + cabal project doesn't resolve, nothing else can proceed. Every subsequent session depends on `nix develop` and `cabal build` working.

### De-risk strategy: staged dependency introduction

Don't add all 40+ dependencies at once. Instead:

**Step 1: Minimal skeleton (10 minutes)**
```
build-depends: base >= 4.17 && < 5, text, bytestring, containers
```
Verify: `nix develop` works, `cabal build` compiles an empty `Main.hs`.

**Step 2: Add YAML + JSON deps**
```
+ aeson, HsYAML, yaml, vector, unordered-containers
```
Verify: `cabal build` still succeeds. Write a trivial YAML parse test.

**Step 3: Add CLI + terminal deps**
```
+ optparse-applicative, ansi-terminal, terminal-size
```
Verify: `cabal build` succeeds. Note: removed brick/vty per S10.

**Step 4: Add AWS deps (the dangerous part)**
```
+ amazonka, amazonka-cloudformation, amazonka-s3, amazonka-ssm, amazonka-sts, amazonka-kms, amazonka-sns
```
Verify: `cabal build` succeeds. This step is most likely to fail due to version conflicts.

**Step 5: Add remaining utility deps**
```
+ mtl, transformers, stm, async, unliftio, req, http-conduit, http-types, network-uri
+ mustache, crypton, base64-bytestring, base16-bytestring, uuid, random, regex-tdfa
+ Diff, time, directory, filepath, process, temporary, Glob, word-wrap, monad-logger, casing
```

### GHC version selection

**Recommendation: GHC 9.4.8 with nixpkgs 24.05 or 24.11.**

Rationale:
- amazonka 2.0 is tested with GHC 9.2-9.4
- GHC 9.6 introduced breaking changes to `base` that affect some packages
- GHC 9.4.8 is the most recent patch of the 9.4 series, well-tested
- nixpkgs 24.05 has GHC 9.4.8 in `haskell.compiler.ghc948`

**Fallback**: If 9.4.8 has issues, try GHC 9.2.8 (maximally conservative).

### Flake.nix skeleton

The agent should use this pattern for the flake.nix:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        hsPkgs = pkgs.haskell.packages.ghc948;  # or ghc96 as fallback
      in {
        devShells.default = hsPkgs.shellFor {
          packages = p: [ ];  # will be populated
          buildInputs = [
            hsPkgs.cabal-install
            hsPkgs.ghc
            hsPkgs.haskell-language-server  # optional, useful for agent
            pkgs.pkg-config
            pkgs.zlib  # needed by many Haskell packages
          ];
        };
      });
}
```

**Critical: include `zlib` in buildInputs.** Many Haskell packages (including amazonka) depend on zlib via C FFI, and it won't be found without this.

### Verification sequence for bootstrapping

The agent should run these checks in order and STOP at the first failure:

```bash
# 1. Enter dev shell
nix develop

# 2. Verify GHC version
ghc --version  # Should be 9.4.8 or 9.6.x

# 3. Verify cabal
cabal --version

# 4. Initialize and build
cabal update
cabal build all  # with the minimal dependency set first

# 5. Run a smoke test
cabal run iidy-hs -- --help  # should show usage
```

If step 1 fails: Nix flake issue. Check GHC availability in nixpkgs pin.
If step 4 fails: Dependency resolution issue. Check cabal.project constraints.
If step 5 fails: Code issue. Normal development.

### Time budget for bootstrapping

Allocate a full session (Session 1) to JUST bootstrapping + types. If bootstrapping alone takes more than 30 minutes of model time, something is fundamentally wrong and the agent should stop and report.

---

## Additional Recommendations

### 1. Add a pre-session checklist to the agent prompt

When invoking `claude -p` for each session, include:
```
Before starting work:
1. Read HANDOFF.md for previous session state
2. Run `git status` and `git log --oneline -3`
3. Run `nix develop --command cabal build 2>&1 | tail -20` to verify build state
4. Run `free -h` to check available memory
5. Read WORKPLAN.md to identify next chunk
6. If available memory < 4GB, warn: "Low memory - builds may OOM. Reduce parallelism."
All git commits must use --no-gpg-sign.
```

### 2. Add explicit failure escalation rules

```
If any of these occur, STOP and write a note to HANDOFF.md rather than retrying:
- Same compilation error after 3 different fix attempts
- OOM during build after reducing to jobs:1 and -O0
- Dependency resolution failure after trying 2 different GHC versions
- Network failure that persists for > 2 minutes
- A sub-agent produces output that fails compilation 2 times after integration fixes
```

### 3. Track actual vs. estimated tokens per session

Add a row to the session tracking table:
```
| Session | Phase | Chunks | Status | Est. context | Actual context |
```
This calibrates future estimates and lets the user see if sessions are running hot.

### 4. Consider a "canary build" at the start of each session

Before doing any new work, rebuild the project from scratch:
```bash
cabal clean && cabal build 2>&1 | tail -5
```
This catches cases where the previous session left the project in an inconsistent state (e.g., stale .hi files, partial builds).

### 5. The workplan underestimates LOC

The workplan estimates ~19,000 LOC Haskell (17,550 production + 1,450 test). This is 106% of the Rust LOC, which contradicts the initial estimate of 65-75%. The discrepancy is acknowledged ("Haskell's terser syntax is offset by more explicit type signatures and the verbose amazonka lens API") but should be treated as a risk. If LOC grows beyond 20K, sessions will take longer and the project timeline extends.

### 6. Remove brick/vty from dependencies

Per architectural decision #5 and stuck state S10, the workplan's dependency list includes `brick`, `vty`, and `vty-crossplatform` but the architecture says these aren't needed. Remove them to:
- Reduce dependency resolution complexity
- Reduce build time and memory usage
- Avoid confusing the agent with unused dependencies
