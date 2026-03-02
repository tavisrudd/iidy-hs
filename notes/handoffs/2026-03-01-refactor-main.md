# Refactor app/Main.hs — Reduce Logic, Minimal Plumbing Only

**Date**: 2026-03-01
**References**: `app/Main.hs` (499 LOC), Session 41 handoff

## Context

`app/Main.hs` has grown to ~500 LOC and contains substantial business logic
that belongs in library modules: AWS env creation, stack-args merging,
credential detection, output dispatch setup, command metadata emission,
timing provider selection, and the full `runCfnWithArgs` orchestration.

The executable entry point should be minimal plumbing: parse CLI, dispatch
to library functions, handle exit codes. All orchestration logic should
live in `src/Iidy/` where it can be tested and reused.

## Instructions for Next Agent

**Do NOT start implementing immediately.** First:

1. Read `app/Main.hs` in full
2. Identify each block of logic that isn't pure CLI plumbing
3. Research where each block should move (existing modules or new ones)
4. Write a chunked plan in the "Chunks" section below
5. Get user approval before implementing

Key areas likely needing extraction:
- `runCfnWithArgs` (~80 lines of orchestration) → new `Iidy.Cfn.Runner` or similar
- `createAwsEnv` / credential detection → `Iidy.Aws.Config` or `Iidy.Aws.Auth`
- `timeProviderForOperation` → already in Timing, may just need re-export
- `generateToken` → small utility, could stay or move
- Signal handler setup → could be a library helper
- Output dispatch wiring → `Iidy.Output.Manager` already exists, may absorb more

The goal: `app/Main.hs` should be ~100-150 LOC of `main = parseCliOpts >>= dispatch`
style plumbing.

## Codebase Reference

| What                      | Where                                |
|---------------------------|--------------------------------------|
| Main.hs                   | `app/Main.hs` (499 LOC)             |
| Output dispatch           | `src/Iidy/Output/Manager.hs`        |
| Timing providers          | `src/Iidy/Aws/Timing.hs`            |
| CfnContext creation       | `src/Iidy/Cfn/Context.hs`           |
| StackArgs loading         | `src/Iidy/Cfn/StackArgsLoader.hs`   |
| Command metadata          | `src/Iidy/Cfn/CommandMetadata.hs`    |
| CLI types                 | `src/Iidy/Cli.hs`                   |

## Build/Test Commands

Per CLAUDE.md.

## Delegation Strategy

- **Planning phase**: Opus — needs architectural judgment about module boundaries
- **Implementation chunks**: Sonnet — mechanical extraction once boundaries decided
- **Review**: Opus — verify no behavior changes, clean module interfaces

## Workflow Instructions

1. Read this file
2. Read `app/Main.hs` in full
3. Plan the extraction (write chunks below)
4. Get user approval
5. Implement chunk by chunk, each leaving tests green
6. Update Progress below after each chunk

## Progress

- [ ] Plan: read Main.hs, design module boundaries, write chunks
- [ ] Extract orchestration logic to library modules
- [ ] Slim Main.hs to ~100-150 LOC plumbing
- [ ] Build clean + all tests pass

## Handoff Notes

(none yet)
