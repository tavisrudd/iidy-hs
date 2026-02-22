# create-stack: Output Sequencing Analysis

## Rust Output Sequence

```
1. CommandMetadata                    — before AWS call
2. TokenInfo                         — during perform_stack_creation, before API returns
3. StackDefinition (show_times=true) — after API returns, fetched via async task
4. NewStackEvents (loop)             — live polling via watch_stack_live_events_with_seen_events
5. OperationComplete                 — after terminal status
6. StackContents                     — after terminal status (skipped if DELETE_COMPLETE)
7. FinalCommandSummary               — last output always
```

Expected sections (renderer ordering):
`["command_metadata", "stack_definition", "live_stack_events", "stack_contents"]`

### Paths

**Normal path**: All 7 outputs in order.

**Rollback/delete path** (DELETE_COMPLETE): Steps 1-5, then FinalCommandSummary with success=false, exit code 1. No StackContents.

## Haskell Output Sequence (Current)

```
1. OdNewStackEvents (loop)    — during pollForCompletion
2. OdStackContents            — after polling, if not DELETE_COMPLETE
```

### Missing in Haskell

| # | Missing Output | Severity |
|---|----------------|----------|
| 1 | CommandMetadata | HIGH — no env/region/credential/token display |
| 2 | TokenInfo | MEDIUM — no client request token display |
| 3 | StackDefinition | HIGH — no stack details before events |
| 4 | OperationComplete | LOW — elapsed time display |
| 5 | FinalCommandSummary | MEDIUM — no success/failure summary |

### Fix Plan

After `resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req` and extracting `stackId`:

1. Emit `OdStackDefinition` by calling `getStack ctx stackName` + `convertStack`
2. Then poll as currently

For CommandMetadata, TokenInfo, FinalCommandSummary — these require shared infrastructure
(see cross-cutting.md).

### Relevant Code

- **Rust**: `~/src/iidy/src/cfn/create_stack.rs` lines 21-117
- **Haskell**: `src/Iidy/Cfn/Operations/CreateStack.hs` lines 67-104
- **Renderer**: `src/Iidy/Output/Renderers/Interactive.hs` renderStackDefinition (line 324)
