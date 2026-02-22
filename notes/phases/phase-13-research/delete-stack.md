# delete-stack: Output Sequencing Analysis

## Rust Output Sequence

### Path A: Stack Absent

```
1. CommandMetadata
2. StackAbsentInfo (env, region, account, auth_arn from STS)
3. FinalCommandSummary (success=true)
```

Exit code 0. Uses STS GetCallerIdentity for account/auth_arn.

### Path B: Stack Exists, Confirmation Denied

```
1. CommandMetadata
2. StackDefinition (show_times=true)
3. StackEvents ("Previous Stack Events (max 10):")   — fetched in parallel with contents
4. StackContents                                      — fetched in parallel with events
5. ConfirmationPrompt ("Are you sure you want to DELETE...")
6. [User types "n"]
7. FinalCommandSummary (success=false)
```

Exit code 130.

### Path C: Stack Exists, Confirmed (or --yes)

```
1. CommandMetadata
2. StackDefinition (show_times=true)
3. StackEvents ("Previous Stack Events (max 10):")
4. StackContents
5. ConfirmationPrompt (if not --yes)
6. [User types "y" or --yes skips]
7. NewStackEvents (loop) — live polling during deletion
8. FinalCommandSummary
```

Expected sections (with --yes): `["command_metadata", "stack_definition", "stack_events", "stack_contents", "live_stack_events"]`
Expected sections (no --yes): `["command_metadata", "stack_definition", "stack_events", "stack_contents", "confirmation", "live_stack_events"]`

## Haskell Output Sequence (Current)

### Stack Absent

```
(returns Right 0 silently — no output at all)
```

### Stack Exists, Confirmation

```
1. Direct stdout: "Are you sure you want to DELETE the stack X? [y/N] "
2. [If confirmed]:
   2a. OdNewStackEvents (loop) — during pollForCompletion
```

### Missing in Haskell

| # | Missing | Severity |
|---|---------|----------|
| 1 | CommandMetadata | HIGH |
| 2 | StackDefinition BEFORE confirmation | **CRITICAL** — user can't see what they're deleting |
| 3 | StackEvents (previous) BEFORE confirmation | HIGH |
| 4 | StackContents BEFORE confirmation | HIGH |
| 5 | StackAbsentInfo with STS context | HIGH — currently silent on absent stack |
| 6 | FinalCommandSummary | MEDIUM |
| 7 | Confirmation via OutputData/renderer | MEDIUM — currently direct I/O |

### Fix Plan

1. When stack absent: call STS GetCallerIdentity, construct StackAbsentInfo, emit it
2. When stack exists, BEFORE confirmation:
   - Fetch stack via getStack + convertStack → emit OdStackDefinition
   - Fetch events via fetchStackEvents + buildEventsDisplay → emit OdStackEvents
   - Collect contents → emit OdStackContents
3. Then show confirmation prompt
4. Need to export `convertStack` and `buildEventsDisplay` from DescribeStack module

### Relevant Code

- **Rust**: `~/src/iidy/src/cfn/delete_stack.rs` lines 84-220
- **Haskell**: `src/Iidy/Cfn/Operations/DeleteStack.hs` lines 63-123
- **StackAbsentInfo renderer**: `src/Iidy/Output/Renderers/Interactive.hs` line 749
