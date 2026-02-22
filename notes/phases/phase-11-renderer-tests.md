# Phase 11: Renderer Output Tests

**Status**: NOT STARTED
**Depends on**: Phase 10 (wiring)

## Problem Statement

The Rust side identified this same gap (see `~/src/iidy/notes/handoffs/2026-02-19-renderer-output-capture.md`):
their renderer writes directly to stdout via `println!()` so tests can't capture output.
They planned a writer-injection refactor but haven't done it yet.

Our Haskell renderer is already in better shape — `renderOutputData` returns `IO ()`
but the formatting functions are mostly pure (Text → Text). We can test the formatting
layer directly without capturing stdout.

## Approach

Unlike Rust (which needs to refactor 94 println! calls), we can:
1. Test `formatSectionHeading`, `formatStackDefinition`, `formatStackEvent`, etc. as pure functions
2. Test `renderOutputData` by capturing stdout with a buffer
3. Snapshot-test full rendered output for each OutputData constructor
4. Test color/no-color and theme variants

## Chunks

### 11.1: Pure Formatting Unit Tests

Test every formatting helper in Interactive.hs with known inputs:

- [ ] `formatSectionHeading` — bold + color + colon
- [ ] `colorizeResourceStatus` — green/yellow/red/grey for each status family
- [ ] `colorByEnvironment` — red for production, blue for integration, green for development
- [ ] `formatLogicalId` — resource ID color
- [ ] `styleMuted` — muted color
- [ ] `formatTimestamp` — "Mon Feb 22 2026 15:30:45" format
- [ ] Column padding (`calcPadding` or equivalent)
- [ ] `formatSingleEvent` — timestamp + status + type + logical ID + duration
- [ ] Changeset change formatting — Add/Modify/Remove with colors
- [ ] Stack list entry formatting — lifecycle icons, tags, env color

Each test: verify exact output string, including ANSI codes for colored variant,
plain text for noColor variant.

### 11.2: OutputData Rendering Snapshots

For each `OutputData` constructor, create a canonical test value and snapshot the
rendered output (both colored and plain):

- [ ] `OdCommandMetadata` — key-value aligned metadata block
- [ ] `OdStackDefinition` — multi-field stack info block
- [ ] `OdStackEvents` — event table with title
- [ ] `OdStackContents` — resources/outputs/exports tables
- [ ] `OdStackList` — multi-column stack listing with env colors
- [ ] `OdChangeSetResult` — changeset with Add/Modify/Remove entries
- [ ] `OdStatusUpdate` — info/warning/error/success levels
- [ ] `OdFinalCommandSummary` — success/failure with elapsed time
- [ ] `OdNewStackEvents` — live event batch
- [ ] `OdStackDrift` — drift table with property differences
- [ ] `OdError` — error with suggestions
- [ ] `OdStackTemplate` — raw template passthrough

Snapshot format: golden file in `test/snapshots/renderer/` with ANSI codes stripped.
Separate golden files for colored output if desired.

### 11.3: Theme Variant Tests

- [ ] Dark theme: verify specific xterm color codes in output (252, 253, 255, etc.)
- [ ] Light theme: verify different color values
- [ ] High contrast: verify bright ANSI colors
- [ ] No color: verify zero ANSI escapes

### 11.4: JSON Renderer Tests

- [ ] Each OutputData → valid JSON object with "type" and "data" fields
- [ ] JSONL format: one line per item, no trailing comma
- [ ] Timestamps in ISO8601 format
- [ ] Verify all 21 OutputData constructors produce parseable JSON

### 11.5: End-to-End Rendering Pipeline Tests

- [ ] `describe-stack` mock → renderer → verify formatted output contains
  stack name, status, resources table, outputs, events
- [ ] `list-stacks` mock → renderer → verify table with columns aligned
- [ ] `watch-stack` mock events → renderer → verify colored event stream
- [ ] Plain mode: same data → no ANSI codes
- [ ] JSON mode: same data → valid JSONL

## Gate Criteria
```bash
cabal test                              # all pass, zero warnings
# Each OutputData constructor has at least one rendering test
# Theme variants tested (dark, light, high-contrast, noColor)
# JSON renderer tested for all OutputData types
# No regressions in existing 265+ tests
```

## Notes

- The Rust side identified this as their biggest test gap. We should not repeat it.
- Our Haskell code is more testable by design — formatting functions are largely pure.
- Snapshot files should be committed alongside tests for regression detection.
- Normalize timestamps and ARNs in snapshots to avoid flaky tests.
