# update-stack: Output Sequencing Analysis

## Rust Output Sequence

### Path A: Direct Update (no --changeset)

```
1. CommandMetadata                    — always first
2. TokenInfo                         — before update API call
3. [watch_stack_operation_and_summarize]:
   3a. StackDefinition               — fetched async
   3b. NewStackEvents (loop)         — live polling
   3c. OperationComplete             — elapsed time
   3d. StackContents                 — after terminal status
   3e. FinalCommandSummary           — last
```

Expected sections: `["command_metadata", "stack_definition", "live_stack_events", "stack_contents"]`

### Path B: Changeset Update (--changeset, no --yes)

```
1. CommandMetadata
2. StackDefinition                   — fetched async, shown before changeset
3. [create_changeset_comprehensive]  — spinner while waiting
4. ChangeSetResult                   — changeset details
5. ConfirmationPrompt                — "Execute this changeset?"
6. [If confirmed, delegates to exec_changeset sequence]:
   6a. TokenInfo
   6b. StackEvents (previous)
   6c. [watch_stack_operation_and_summarize]
   6d. FinalCommandSummary
```

Expected sections (with --yes): `["command_metadata", "stack_definition", "changeset_result"]`
Expected sections (no --yes): `["command_metadata", "stack_definition", "changeset_result", "confirmation"]`

### Path C: No Updates Needed

```
1. CommandMetadata
2. (error caught: "No updates are to be performed")
3. FinalCommandSummary (success=true)
```

Returns exit code 0.

## Haskell Output Sequence (Current)

### Direct Update

```
1. OdNewStackEvents (loop)    — during pollForCompletion
2. OdStackContents            — after polling
```

### No Updates

```
(no output — returns Right 0 silently)
```

### Changeset Path

**NOT IMPLEMENTED.** `updateStack` has no changeset path at all.

### Missing in Haskell

| # | Missing | Severity |
|---|---------|----------|
| 1 | CommandMetadata | HIGH |
| 2 | TokenInfo | MEDIUM |
| 3 | StackDefinition before events | HIGH |
| 4 | OperationComplete | LOW |
| 5 | FinalCommandSummary | MEDIUM |
| 6 | Changeset path entirely | **CRITICAL** — --changeset flag exists in CLI but is ignored |
| 7 | "No updates" message via StackChangeDetails | MEDIUM — currently silent |

### Fix Plan

1. Add StackDefinition emission before polling (same pattern as create-stack)
2. Emit StackChangeDetails(UpdateNoChanges) on "no updates" path
3. **Changeset path**: implement update_stack_with_changeset — create changeset,
   show result, confirm, execute. This is substantial new code (~80 LOC).

### Relevant Code

- **Rust**: `~/src/iidy/src/cfn/update_stack.rs` lines 15-167
- **Haskell**: `src/Iidy/Cfn/Operations/UpdateStack.hs` lines 75-136
