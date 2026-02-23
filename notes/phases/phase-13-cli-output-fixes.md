# Phase 13: CLI Output Fixes (Live Testing + Full Audit)

## Context

Live testing of `iidy-hs` vs `iidy-rs` (captured in `cli-output-tests-rs-vs-hs.ansii.txt`)
revealed multiple output divergences. Only 3 commands were tested (describe-stack,
create-stack, delete-stack). A full audit of all 22 commands revealed the scope is
much larger than initially apparent.

## Per-Command Research

Detailed Rust-vs-Haskell side-by-side analysis for each command:

| Command | Research File | Severity |
|---------|---------------|----------|
| create-stack | [create-stack.md](phase-13-research/create-stack.md) | HIGH — missing 5 output steps |
| update-stack | [update-stack.md](phase-13-research/update-stack.md) | **CRITICAL** — changeset path unimplemented |
| create-or-update | [create-or-update.md](phase-13-research/create-or-update.md) | **CRITICAL** — changeset path unimplemented, 5 paths |
| delete-stack | [delete-stack.md](phase-13-research/delete-stack.md) | HIGH — no pre-confirmation display |
| describe-stack | [describe-stack.md](phase-13-research/describe-stack.md) | HIGH — missing headings + error handling |
| watch-stack | [watch-stack.md](phase-13-research/watch-stack.md) | HIGH — missing definition, previous events, inactivity timeout |
| changeset ops | [changeset.md](phase-13-research/changeset.md) | **CRITICAL** — create-changeset result never shown |
| list-stacks | [list-stacks.md](phase-13-research/list-stacks.md) | OK — only region bug affects this |
| describe-stack-drift | [describe-stack-drift.md](phase-13-research/describe-stack-drift.md) | **CRITICAL** — only initiates, never shows results |
| estimate-cost | [estimate-cost.md](phase-13-research/estimate-cost.md) | LOW — works but bypasses renderer |
| lint-template | [lint-template.md](phase-13-research/lint-template.md) | MEDIUM — raw error vs styled output |
| template-approval | [template-approval.md](phase-13-research/template-approval.md) | MEDIUM — works but bypasses renderer |
| get-stack-template | [get-stack-template.md](phase-13-research/get-stack-template.md) | OK — functionally correct |
| convert-stack | [convert-stack.md](phase-13-research/convert-stack.md) | OK — both use direct stderr |
| cross-cutting | [cross-cutting.md](phase-13-research/cross-cutting.md) | — all shared issues |
| edge cases | [edge-cases.md](phase-13-research/edge-cases.md) | — behavioral edge cases |

## Severity Summary

### CRITICAL (feature gaps — not just output formatting)

1. **update-stack --changeset path**: CLI flag exists, parameter accepted, completely ignored.
   Rust has full changeset-based update flow with confirmation.
2. **create-or-update --changeset path**: Same — `_useChangeset` parameter ignored (line 42).
   Rust has 5 distinct paths; Haskell has 2.
3. **create-changeset result never rendered**: `createChangeset` returns `ChangeSetInfo` but
   Main.hs discards it. User never sees changeset details, console URL, or changes.
4. **describe-stack-drift incomplete**: Only initiates drift detection and returns detection ID.
   Rust polls to completion and shows actual drift results. The command is non-functional.

### HIGH (output sequencing gaps)

5. **Missing section headings**: `renderStackEvents` and `renderStackContents` never print
   their section headings. Affects describe-stack, delete-stack, watch-stack, exec-changeset.
6. **No CommandMetadata**: Never emitted by any operation. Missing env/region/credential display.
7. **No FinalCommandSummary**: Never emitted. No success/failure + elapsed time display.
8. **delete-stack pre-confirmation**: No stack details shown before "Are you sure?"
9. **create-stack/update-stack/watch-stack missing StackDefinition**: Stack details never shown
   before live events start.
10. **Stack absent error formatting**: Raw error text vs styled StackAbsentInfo with STS context.
11. **exec-changeset missing previous events**: No "Previous Stack Events" shown before live events.
12. **watch-stack missing initial display**: No StackDefinition, no previous events, no StackContents
    after completion. Inactivity timeout parameter ignored.

### MEDIUM

13. **Console URL wrong encoding**: Slashes URL-encoded in stack info URL (shouldn't be).
14. **Region resolution priority**: `AWS_DEFAULT_REGION` checked before `AWS_REGION`.
15. **lint-template output**: Raw exception vs styled TemplateValidation.
16. **template-approval output**: Works but bypasses renderer styling.
17. **estimate-cost output**: Works but bypasses renderer.
18. **No spinners**: Module exists, never wired.
19. **AWS auth timeout**: Hangs on missing credentials.
20. **watch-stack inactivity timeout unimplemented**: CLI accepts `--inactivity-timeout`
    (default 180s) but `_timeoutSeconds` parameter is unused. Polling runs until terminal
    state or forever. Rust tracks last-event-time and emits InactivityTimeoutInfo.
21. **No overall poll timeout**: `pcTimeoutSeconds` field exists in PollConfig but
    `pollForCompletionWith` never checks it. Rust defaults to 3600s. Stuck operations
    poll forever.
22. **Changeset name generation**: Haskell falls back to hardcoded "changeset", Rust
    generates docker-style random names. Second run without explicit name will fail.
23. **Event duration not calculated**: `sewDurationSeconds` always `Nothing`. Rust
    calculates elapsed time from first to terminal event and shows e.g. "(3s)".

## Execution Plan

This is too large for one phase. Split into sub-phases:

### 13.1 — Quick renderer fixes (1 session)
- Section headings in renderStackEvents + renderStackContents
- Console URL encoding fix
- Region priority fix
- Export `convertStack`, `buildEventsDisplay` from DescribeStack

### 13.2 — STS + error infrastructure (1 session)
- Add `getCallerIdentity` utility (STS call)
- Fix describe-stack missing-stack error → StackAbsentInfo
- Fix delete-stack missing-stack path → StackAbsentInfo

### 13.3 — Pre-confirmation + definition display (1-2 sessions)
- delete-stack pre-confirmation: show definition + events + contents before prompt
- create-stack: emit StackDefinition before polling
- update-stack: emit StackDefinition before polling
- watch-stack: emit StackDefinition + previous events, emit StackContents after

### 13.4 — CommandMetadata + FinalCommandSummary (1 session)
- Build `constructCommandMetadata` helper
- Wire into all write operations
- Build FinalCommandSummary emission after each operation

### 13.5 — Changeset paths (DONE, Sessions 30-31)
- ✅ update-stack --changeset: create changeset, show result, confirm, execute
- ✅ create-or-update --changeset: both create and update changeset paths (all 5 paths)
- ✅ create-changeset: render ChangeSetResult with console URL, random name generation, stack state detection
- ✅ exec-changeset: previous events before live events, StackContents after
- ✅ Changeset console URL encoding (DO encode, unlike stack info URLs)
- ✅ generateDashedName, checkStackState, confirmChangesetExecution shared helpers
- ✅ Consistency analysis doc: notes/changeset-consistency-analysis.md

### 13.6 — describe-stack-drift completion (1 session)
- Poll DescribeStackDriftDetectionStatus until complete
- Call DescribeStackResourceDrifts for actual results
- Show StackDefinition first, then drift results

### 13.7 — Minor operation fixes (1 session)
- lint-template: use TemplateValidation OutputData
- estimate-cost: use CostEstimate OutputData
- template-approval request/review: use OutputData variants

### 13.8 — Polling infrastructure + timeouts (1-2 sessions)
- Implement inactivity timeout in watch-stack (track last-event-time, emit InactivityTimeoutInfo)
- Implement overall poll timeout in pollForCompletionWith (check pcTimeoutSeconds)
- Calculate event durations (sewDurationSeconds) on terminal events
- Generate random changeset names when user doesn't specify (port generate_dashed_name or use UUID)
- Wire spinner into pollForCompletion idle periods
- Add timeout to Amazonka.discover
- OperationComplete emission after polling

### 13.9 — Output sequence integration tests (1-2 sessions)
- Per-command output sequence tests with mocked AWS
- Full render integration tests (capture stdout, compare golden files)
- Error path integration tests

## Testing Gap Analysis

### Why existing tests missed these issues

All 352 tests are unit/snapshot tests against mock fixtures. They test individual
rendering functions in isolation but never test:

1. **Output emission sequence** — No test verifies that create-stack emits
   `OdStackDefinition` → poll events → `OdStackContents` in that order. Operation
   functions were tested for return values, not for what they emit.

2. **Section headings in context** — `renderStackEvents` receives `sedTitle` but no
   test checks it gets printed. Snapshot tests compare rendered content, not heading +
   content combined.

3. **End-to-end command flow** — No test runs `CmdDescribeStack` through `runCommand`
   and captures full stdout to verify output structure.

4. **Error paths with AWS error types** — describe-stack's `Left "Stack not found"`
   was never tested for how it actually renders vs Rust.

5. **Cross-component integration** — Operation → OutputData emission → Renderer
   pipeline was never tested as a whole. Each piece tested in isolation.

### Testing improvements (13.9)

1. **Output sequence tests**: Mock AWS calls, capture the sequence of `OutputData`
   values emitted by each operation. Assert exact variant sequence.

2. **Full render integration tests**: For each command, capture complete stdout
   from `renderOutputData` applied to the OutputData sequence.
   Compare against golden files.

3. **Error rendering tests**: Test full error path — AWS error → ErrorInfo →
   rendered output.

These are testable offline with mocks. The gap was testing individual components
without testing their composition.
