# AWS API Call Efficiency Fixes -- Bug Fix Batch

**Date**: 2026-03-01
**Session**: `9b77427d-2cd4-4c4b-a7a0-d2726e72261d`
**References**: Review loop 3 (OPS-07), Rust `src/cfn/stack_operations.rs`, `src/output/aws_conversion.rs`

## Context

Review loop 3 flagged a performance issue in `collectStackContents` (OPS-07):
it fetched ALL CloudFormation exports in the AWS account via paginated
`ListExports`, then filtered client-side. A broader audit of all AWS API calls
in `src/Iidy/Cfn/` found 4 additional issues: full-history event pagination
on every poll cycle, missing pagination in listStacks, sequential API calls
in collectStackContents, and redundant DescribeStacks calls.

## Issues Fixed

### A. ListExports → derive from stack outputs (HIGH)

`collectStackContents` called `ListExports` (paginated, all account exports)
then filtered by stack ARN. Rust derives exports from stack outputs — zero
extra API calls. The Haskell code comment "This matches the Rust
implementation" was wrong.

**Fix**: Replaced 20-line ListExports pagination block with a 12-line list
comprehension filtering outputs by `soiExportName`. Removed `LE` import.

### B. fetchStackEvents full pagination → single page (HIGH)

`fetchStackEvents` paginated the entire event history on every call. The
polling loop called it every 2 seconds. For a stack with 500+ events across
10 pages, that's 10 API calls per cycle × 300 cycles = 3000 unnecessary calls.

Rust fetches a single page (newest events first). New events always appear
on page 1.

**Fix**: Added `fetchRecentStackEvents` (single `Amazonka.send`, no
pagination). Updated `pollForCompletion` and all 4 event display callers
(describeStack, deleteStack, watchStack, executeChangeset) to use it.
Kept `fetchStackEvents` for any future case needing full history.

Note: `--events` CLI flag (default 50) is only on describe-stack. One page
returns ~100 events, sufficient for the default. Other commands hardcode 10.

### C. listStacks not paginated (HIGH — correctness bug)

`listStacks` used a single `Amazonka.send`, silently truncating at ~100
stacks. Rust paginates with `.into_paginator()`.

**Fix**: Changed to `Amazonka.paginate` with conduit. Added conduit imports.

### D. collectStackContents parallelized (MEDIUM — latency)

Three independent API calls ran sequentially: DescribeStackResources,
DescribeStacks (getStack), ListChangeSets. Rust runs the first two
concurrently.

**Fix**: Added `async` dependency. `collectStackContentsWithStack` runs
DescribeStackResources and ListChangeSets via `concurrently`.

### E. Redundant getStack in collectStackContents (MEDIUM)

Three callers (describeStack, deleteStack, watchStack) already had the stack
object, but `collectStackContents` called `getStack` again.

**Fix**: Added `collectStackContentsWithStack :: CfnContext -> Text -> Maybe
CF.Stack -> IO StackContents`. Updated describeStack and deleteStack to pass
their already-fetched stack. (watchStack calls after polling, stack may have
changed, so it still uses `collectStackContents`.)

### F. Magic number 10 → defaultPreviousEventsCount

Three callers hardcoded `buildEventsDisplay 10` despite
`defaultPreviousEventsCount` existing in `Iidy.Cfn.Constants`.

**Fix**: Added import of `defaultPreviousEventsCount` to DeleteStack,
WatchStack, and Changeset modules.

## Files Modified

| File                                     | Changes                                                |
|------------------------------------------|--------------------------------------------------------|
| `iidy-hs.cabal`                          | Added `async` dependency                               |
| `src/Iidy/Cfn/StackOperations.hs`       | fetchRecentStackEvents, collectStackContentsWithStack, concurrently, exports from outputs |
| `src/Iidy/Cfn/Operations/DescribeStack.hs` | Use fetchRecentStackEvents + collectStackContentsWithStack |
| `src/Iidy/Cfn/Operations/DeleteStack.hs` | Use fetchRecentStackEvents + collectStackContentsWithStack + constant |
| `src/Iidy/Cfn/Operations/WatchStack.hs`  | Use fetchRecentStackEvents + constant                  |
| `src/Iidy/Cfn/Operations/Changeset.hs`   | Use fetchRecentStackEvents + constant                  |
| `src/Iidy/Cfn/Operations/ListStacks.hs`  | Paginate with conduit                                  |

## Verification

- Build: zero warnings (`-Wall -Wcompat`)
- Tests: 851 pass
- No behavioral changes for any downstream consumer

## Handoff Notes

### Completion (2026-03-01)

**Session**: `9b77427d-2cd4-4c4b-a7a0-d2726e72261d`
**Completed**: All 6 issues (A-F) fixed in one session.
**Deviations from plan**: Originally planned only the allExports fix.
Broadened to full audit after user asked "are we doing anything silly
like that elsewhere?" Found and fixed 5 more issues.
**Notes**: The `fetchStackEvents` (full pagination) function is still
exported but currently unused — kept for potential future use. Could be
removed if never needed. The `--events` flag on describe-stack defaults to
50; one page returns ~100, so single-page fetch covers it. If someone
passes `--events 200` they'd get at most ~100, with truncation info
displayed correctly.
