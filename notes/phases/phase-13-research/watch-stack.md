# watch-stack: Output Sequencing Analysis

## Rust Output Sequence

```
1. StackDefinition                                   — fetched async, shown first
2. StackEvents ("Previous Stack Events (max N):")    — previous events with heading
3. NewStackEvents (live loop)                        — live polling with 2s intervals
4. OperationComplete or InactivityTimeout            — when terminal status or timeout
5. StackContents                                     — after terminal (skipped if DELETE_COMPLETE)
```

Expected sections: `["stack_definition", "stack_events", "live_stack_events", "stack_contents"]`

No CommandMetadata, no FinalCommandSummary (observation-only command).

### Paths

**Normal completion**: Steps 1-5, exit 0.
**Inactivity timeout**: Steps 1-3, InactivityTimeout instead of OperationComplete, exit 0.
**DELETE_COMPLETE**: Steps 1-4, skip StackContents, exit 0.
**Stack not found**: Error, exit via Left.

## Haskell Output Sequence (Current)

```
1. OdNewStackEvents (via callback from Main.hs) — during pollForCompletion
```

Main.hs lines 140-149 set up the callback, which converts events and calls
`renderOutput dispatch (OdNewStackEvents converted)`.

### Missing in Haskell

| # | Missing | Severity |
|---|---------|----------|
| 1 | StackDefinition | HIGH — no stack details shown before events |
| 2 | StackEvents (previous) | HIGH — no previous events with heading |
| 3 | StackContents after completion | MEDIUM — collected but discarded (line 88) |
| 4 | OperationComplete | LOW — elapsed time |
| 5 | InactivityTimeout output | MEDIUM — timeout happens but not announced |
| 6 | _timeoutSeconds parameter ignored | MEDIUM — line 60, inactivity timeout not implemented |

### Fix Plan

1. Before polling, fetch and emit StackDefinition + previous StackEvents
2. After polling, emit StackContents (currently collected then discarded)
3. Implement inactivity timeout (currently `_timeoutSeconds` is unused)
4. watchStack needs `emit` callback or needs to return `[OutputData]` for pre-poll data

### Relevant Code

- **Rust**: `~/src/iidy/src/cfn/watch_stack.rs` lines 45-144
- **Haskell**: `src/Iidy/Cfn/Operations/WatchStack.hs` lines 54-90
