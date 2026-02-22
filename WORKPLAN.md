# iidy-hs Workplan

**Target**: Feature-complete, behavior-identical, output-identical Haskell port. No shortcuts, no dropped features.
**Status**: Phases 1-9 complete (YAML engine, CFN ops, error display, tests). Phases 10-11 needed: output pipeline wiring + renderer tests.

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
| 7 | Error display system | **DONE** (Sessions 13-17) | [phase-7-error-display.md](notes/phases/phase-7-error-display.md) |
| 8 | Remaining features (NTP, schema, demo, exception handling) | **DONE** (8.1-8.6 complete) | [phase-8-remaining-features.md](notes/phases/phase-8-remaining-features.md) |
| 9 | Final verification | **DONE** (all verified) | [phase-9-final-verification.md](notes/phases/phase-9-final-verification.md) |
| 10 | Output pipeline wiring | **DONE** | [phase-10-output-wiring.md](notes/phases/phase-10-output-wiring.md) |
| 11 | Renderer output tests | **DONE** | [phase-11-renderer-tests.md](notes/phases/phase-11-renderer-tests.md) |
| 12 | Completion audit vs Rust (iterative) | **NOT STARTED** | [phase-12-completion-audit.md](notes/phases/phase-12-completion-audit.md) |

Phase 12 is iterative: audit → triage → create fix phases (13, 14, ...) → re-audit.
Loop until a full audit pass finds zero new offline-testable gaps. "Done" means every
behavior testable without live AWS matches Rust, with automated tests and documented divergences.

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
| 25 | 11 | Phase 11 COMPLETE: JSON renderer, theme, rendering output tests. 352 tests. |

**Current: 78 modules, 352 tests, 37/37 render snapshots, 49/49 error snapshots match**

## Remaining Work

Phases 1-11 are complete. Phase 12 (completion audit) is next: systematic
command-by-command comparison against the Rust oracle to verify behavioral parity.

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
