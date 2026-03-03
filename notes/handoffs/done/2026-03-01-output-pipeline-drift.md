# Resolve Output Pipeline ADR Drift -- Review/Plan

**Status**: DONE
**Date**: 2026-03-01
**Session**: `00cdf3e0-e600-42b8-8b73-07f9dcd707ad`
**References**: `docs/dev/adr/001-output-pipeline.md`

## Context

ADR 001 states: "All command output flows through `renderOutput`. Direct `putStrLn` calls
are prohibited in command implementations." However, several command paths still use direct
stdout/stderr writes instead of structured `OutputData` emission.

This handoff documents the drift and plans which writes should be migrated vs. which are
intentionally exempt.

## Audit Results

### HIGH priority — command output that should use OutputData

| Module           | Lines        | What                                    | Suggested OutputData        |
|------------------|--------------|-----------------------------------------|-----------------------------|
| GetImport.hs     | 40, 43, 47   | JSON/YAML/raw import output             | `OdRawOutput` or new variant|
| Render.hs        | 99            | Template render output                  | `OdRawOutput` or new variant|
| Main.hs          | 223           | get-stack-template output               | `OdRawOutput`               |
| Main.hs          | 243, 253, 258| param-get, get-by-path, history output  | `OdRawOutput`               |

### MEDIUM priority — status/progress messages

| Module           | Lines              | What                                    | Suggested OutputData         |
|------------------|--------------------|-----------------------------------------|------------------------------|
| ConvertStack.hs  | 486,491,499,528    | "Wrote <file>" confirmations            | `OdMessage`                  |
| ConvertStack.hs  | 578                | "Writing SSM parameter..." progress     | `OdMessage`                  |
| ConvertStack.hs  | 586                | "WARNING: Failed to write..." warning   | `OdWarning` (new?)           |
| Main.hs          | 248                | "Parameter set successfully."           | `OdMessage`                  |
| Params/Review.hs | 58-62, 73, 76      | Parameter display + status              | `OdMessage` or new variant   |
| InitStackArgs.hs | 99, 102            | File exists / created messages          | `OdMessage`                  |

### EXEMPT — intentionally direct I/O

| Module        | Lines           | Why exempt                                         |
|---------------|-----------------|----------------------------------------------------|
| Confirm.hs    | 23, 25, 26      | Interactive prompt — must be real-time              |
| Demo.hs       | 223-265          | Shell playback — simulates terminal output          |
| Cli/Help.hs   | all              | CLI scaffolding, not command output                 |
| Explain.hs    | all              | Reference display, standalone utility               |
| Main.hs       | 81-87, 100-104   | Exception handlers — stderr is appropriate          |
| Main.hs       | 314-317           | Shell completion scripts — stdout is required       |
| Render.hs     | 52, 68, 80, 87   | Error display — uses enhanced error formatting      |

## Key Decision Needed

Before implementing, decide:

1. **New OutputData variant?** The HIGH-priority items produce raw text/JSON/YAML output
   that doesn't fit existing OutputData variants well. Options:
   - Add `OdRawOutput :: Text -> OutputData` for pass-through text
   - Add `OdCommandResult :: Text -> Maybe Text -> OutputData` (value + optional format hint)
   - Use existing `OdMessage` for everything

2. **Scope**: Fix HIGH only (4 modules, ~10 writes) or HIGH+MEDIUM (7 modules, ~20 writes)?

3. **OutputDispatch threading**: Some commands (get-import, render, param ops) don't currently
   receive an `OutputDispatch` / `CfnContext`. Plumbing the emitter through to these functions
   requires touching their signatures and callers in Main.hs.

## Codebase Reference

| What                 | Where                                          |
|----------------------|------------------------------------------------|
| ADR                  | `docs/dev/adr/001-output-pipeline.md`          |
| OutputData types     | `src/Iidy/Output/Types.hs`                     |
| OutputDispatch       | `src/Iidy/Output/Manager.hs`                   |
| Interactive renderer | `src/Iidy/Output/InteractiveRenderer.hs`       |
| JSON renderer        | `src/Iidy/Output/JsonRenderer.hs`              |
| CfnContext (emitter) | `src/Iidy/Cfn/Types.hs`                        |

## Delegation Strategy

This is primarily an **Opus-level planning task** — the architectural decision about
new OutputData variants and how to plumb emitters through non-CFN commands requires
design thought. Implementation of the mechanical changes (once designed) can be delegated
to Sonnet sub-agents.

- **Phase 1 (Opus)**: Design OutputData additions and plumbing strategy
- **Phase 2 (Sonnet, parallel)**: Implement HIGH-priority migrations
- **Phase 3 (Sonnet, parallel)**: Implement MEDIUM-priority migrations

## Progress

- [ ] Review and decide on approach (OutputData variant, scope, plumbing)
- [ ] Design OutputData additions if needed
- [ ] Migrate HIGH-priority writes
- [ ] Migrate MEDIUM-priority writes (if in scope)
- [ ] Verify all tests pass, no warnings

## Handoff Notes

(to be filled by implementing session)

## Status Notes
Completed in commit 778348c ("Add OdRawOutput variant, begin output pipeline drift resolution"). HIGH-priority items migrated to renderOutput dispatch.
