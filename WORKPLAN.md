# iidy-hs Workplan

**Target**: Feature-complete, behavior-identical, output-identical Haskell port. No shortcuts, no dropped features.
**Status**: Phase 13 COMPLETE. Phase 14 (live verification) next.

## Critical Rules

1. **Feature complete.** Every Rust feature gets ported. NTP time sync, full schema validation, demo command — everything.
2. **Gate integrity.** Never check off a gate item until verified. Opus must verify completion.
3. **Small, frequent green commits.** Each commit includes corresponding doc updates.
4. **Check .msgs/ constantly.** After every tool call chain or natural pause.
5. **No phase advancement** until current phase is truly complete and verified.

## Operational Notes

- Git: `git config --local commit.gpgsign false` (YubiKey hangs)
- Build: `cabal jobs: 4`, `-O0` for dev, use `run-quiet` wrapper
- Testing: ALL offline with mock fixtures. No real AWS calls.
- Rust oracle: `~/src/iidy/target/debug/iidy` (via `nix develop ~/src/iidy`)
- Rust snapshots: `~/src/iidy/tests/snapshots/` (98 .snap files)
- Safety: No destructive ops, no files outside ~/src/iidy-hs/, read-only ~/src/iidy/

## Phase Index

| Phase | Description | Status | Doc |
|-------|-------------|--------|-----|
| 1 | Project skeleton + core types | DONE (Session 1) | — |
| 2 | YAML preprocessing engine | DONE (Sessions 2-3) | — |
| 3 | Output system | DONE (Session 3) | — |
| 4 | AWS + CloudFormation | DONE (Session 4) | — |
| 5 | CLI + remaining commands | DONE (Session 5) | — |
| 6 | Tests + polish | DONE (Sessions 6-11) | — |
| 7 | Error display system | **DONE** (Sessions 13-17) | [done/phase-7](notes/phases/done/phase-7-error-display.md) |
| 8 | Remaining features (NTP, schema, demo, exception handling) | **DONE** (8.1-8.6 complete) | [done/phase-8](notes/phases/done/phase-8-remaining-features.md) |
| 9 | Final verification | **DONE** (all verified) | [done/phase-9](notes/phases/done/phase-9-final-verification.md) |
| 10 | Output pipeline wiring | **DONE** | [done/phase-10](notes/phases/done/phase-10-output-wiring.md) |
| 11 | Renderer output tests | **DONE** | [done/phase-11](notes/phases/done/phase-11-renderer-tests.md) |
| 12 | Completion audit vs Rust (iterative) | **DONE** (Sessions 25-27) | [done/phase-12](notes/phases/done/phase-12-completion-audit.md) |
| 13 | Output sequencing + feature gaps (full audit) | **DONE** (Sessions 28-34) | [phase-13-cli-output-fixes.md](notes/phases/phase-13-cli-output-fixes.md) |
| 14 | Live AWS verification — ALL commands | **PLANNED** | — |
| 15 | AWS auth chain: profile, assume-role, region | **PLANNED** | [aws-auth-chain-analysis.md](notes/aws-auth-chain-analysis.md) |

Phase 12 offline audit found zero gaps, but live AWS testing (Session 28) on just 3 commands
revealed 8 divergences. A full sequencing audit of all 22 commands then uncovered:

- **4 CRITICAL gaps**: changeset paths in update-stack/create-or-update unimplemented
  (CLI flags accepted but ignored), create-changeset result never rendered,
  describe-stack-drift only initiates detection without showing results
- **8 HIGH gaps**: missing section headings, no CommandMetadata/FinalCommandSummary ever
  emitted, no pre-confirmation display in delete-stack, no StackDefinition before live
  events in create/update/watch, no previous events in exec-changeset
- **7 MEDIUM gaps**: console URL encoding, region priority, lint/approval/cost bypass
  renderer, no spinners, auth timeout

Phase 13 had 9 sub-phases (13.1-13.9), all COMPLETE. See per-command research files in
`notes/phases/phase-13-research/` for detailed Rust-vs-Haskell analysis.

Phase 14 is systematic live verification of ALL 22 commands now that Phase 13 is done.

## Session Log

| Session | Phase | Summary |
|---------|-------|---------|
| 1 | 1 | Nix flake, cabal, core types. Gate 1 passed. |
| 2 | 2 | All YAML engine chunks compiled. |
| 3 | 2-3 | Gate 2 passed (27 fixtures), output system. |
| 4 | 4 | All CFN operations + AWS loaders. |
| 5 | 5 | CLI parser, 24 commands, loaders. |
| 6 | 6 | Test infra, 81 tests. |
| 7 | 6 | StackArgsLoader, Main.hs wiring, 89 tests. |
| 8 | 6 | Remaining stubs, TemplateHash, 106 tests. |
| 9 | Polish | Custom resource expansion, 138 tests. |
| 10 | Polish | Emitter fixes, OValue pipeline, 36/36 render snapshots, 181 tests. |
| 11 | Polish | Error snapshot audit: 0/49 match. Gap analysis done. |
| 12 | Meta | Workflow restructuring: per-phase docs, session handoffs, quality gates. |
| 13 | 7 | Phase 7.1: Enhanced error display wired up (Conversion module), research documented. |
| 14 | 7 | Phase 7.2: Error message matching, position tracking — 0→18/49 error snapshots pass. |
| 15 | 7 | Phase 7.2d-h: Position refinement, examples, caret logic — 18→35/49 error snapshots pass. |
| 16 | 7 | Phase 7.3: Validation gaps (11 UNEXPECTED_OK → 0), unknown tags, field validation, CFN validation — 35→44/49 error snapshots pass. |
| 17 | 7-8 | Phase 7.4: Final 5 error snapshots fixed — 49/49 pass. Phase 7 complete. Ctrl-C + exception handling fixed. |
| 18 | 8 | Phase 8.1-8.3, 8.6: NTP time sync, JSON Schema validation, demo command, gate item tests. |
| 19 | 8-9 | YAML 1.1 auto-detection fix, missing fixtures, property tests, memory profiling, final verification. |
| 20 | 8.6 | delete-stack confirmation + changeset conversion tests, warning cleanup. 243 tests. |
| 21 | 8.6 | watch-stack pure function tests (formatEvent, stackNameFromId). 252 tests. |
| 22 | 8.6 | watch-stack mock polling tests (pollForCompletionWith + DI). 258 tests. Phase 8.6 COMPLETE. |
| 23 | 8-9 | Error color audit: --color flag wiring, detectErrorColors, 7 color tests. 265 tests. |
| 24 | 10-11 | Phase 10 COMPLETE: Output pipeline wiring. Phase 11.1: 28 renderer formatting tests. 293 tests. |
| 25 | 11-12 | Phase 11 COMPLETE (352 tests). Phase 12.1: render fixes (JSON, query, overwrite), CLI defaults aligned, list-stacks query/tags wired. |
| 26 | 12 | Phase 12.2: Fix 7 CLI divergences, add 3 missing handlebars helpers, full command audit, DIVERGENCES.md. |
| 27 | 12 | Phase 12.3: Final re-audit pass — zero gaps found. Phase 12 COMPLETE. Port DONE. |
| 28 | 13 | Phase 13 planned: 8 output divergences from live AWS testing. |
| 29 | 13.1-13.3 | Phase 13.1-13.3: Section headings, console URL, region priority, STS getCallerIdentity, StackAbsentInfo, StackDefinition before polling in all ops. |
| 30 | 13.4 | Phase 13.4: CommandMetadata + FinalCommandSummary emission. AWS auth chain analysis (3 critical gaps found). |
| 31 | 13.5 | Phase 13.5: Changeset consistency — all changeset paths implemented (update-stack, create-or-update, create-changeset fixes). |
| 32 | 13.6-13.8 | Phase 13.6-13.8: Drift completion, minor ops through output pipeline, spinner + polling infrastructure. |
| 33 | 13.8+ | Spinner timing display, event duration calculation, describe-stack absent error fix. |
| 34 | 13.9 | Phase 13.9: Integration tests — all 26 OutputData types through both renderers, output sequence tests. Phase 13 COMPLETE. |
| 35 | Docs | Developer documentation: 12 docs + 4 ADRs (2,316 lines) covering architecture, modules, AWS config, output pipeline, testing, Rust compat, security. |

**Offline audit: 80 modules, 379 tests, 37/37 render snapshots, 49/49 error snapshots match**

## Phase 12 Offline Audit Summary

Phase 12 offline audit (Session 27) confirmed code-level completeness:
- All 22 CLI commands match Rust behavior
- All 19 CloudFormation intrinsics implemented
- All 21 preprocessing tags implemented
- All 28 handlebars helpers implemented
- All 50 error codes in explain command
- All environment variables (NO_COLOR, FORCE_COLOR, COLORTERM, COLUMNS, AWS_*)
- Zero `undefined`, zero TODO stubs, zero `Debug.Trace`, zero dead code, zero warnings
- All known divergences documented in DIVERGENCES.md

**However**, live AWS testing (Session 28) revealed 8 output divergences that offline
snapshot testing could not catch — see Phase 13 doc for details.

## Key Architecture Decisions

1. **Monad stack**: Plain IO with CfnContext passed explicitly. `ExceptT` where needed.
2. **YAML**: HsYAML event API with position tracking (not tree-sitter).
3. **Handlebars**: Custom parser/renderer (not mustache pkg).
4. **JMESPath**: Custom minimal impl from spec.
5. **Output**: ansi-terminal for ANSI codes (not brick TUI).
6. **Emitter**: Custom YAML emitter preserving key sort order.
7. **Custom resources**: OValue throughout pipeline for key order preservation.

## Risk Register

| # | Risk | Mitigation |
|---|------|------------|
| R1 | JMESPath: no Haskell library | Custom impl done (~600 LOC) |
| R2 | tree-sitter: no bindings | HsYAML event API instead — done |
| R3 | JSON Schema: hjsonschema deprecated | Must implement full Draft 7 matching Rust's coverage |
| R9 | NTP library | Must implement SNTP (~100 LOC). Critical for CI. |
