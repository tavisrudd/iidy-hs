# Changeset Operations: Output Sequencing Analysis

## create-changeset

### Rust Output Sequence

```
1. CommandMetadata
2. [create_changeset_comprehensive] — internal: spinner while polling changeset status
3. ChangeSetResult                  — changeset details + console URL + next steps
4. FinalCommandSummary
```

Expected sections: `["command_metadata", "changeset_result"]`

### Haskell Output Sequence (Current)

```
(no OutputData emitted — returns Either Text ChangeSetInfo, result discarded in Main.hs)
```

Main.hs lines 113-120: `createChangeset` returns `Right ()` or `Left err`, result
is discarded. The ChangeSetInfo is never rendered.

### Missing in Haskell

| # | Missing | Severity |
|---|---------|----------|
| 1 | CommandMetadata | HIGH |
| 2 | ChangeSetResult rendering | **CRITICAL** — changeset details never shown to user |
| 3 | Console URL for changeset review | HIGH |
| 4 | Next steps instructions | MEDIUM |
| 5 | FinalCommandSummary | MEDIUM |

### Fix Plan

1. Change `createChangeset` to accept `emit` callback or return `[OutputData]`
2. After changeset creation completes, construct `ChangeSetCreationResult` and emit
   `OdChangeSetResult`
3. Need to build console URL (URL-encoded ARNs for changeset URLs, per Rust pattern)

---

## exec-changeset (execute-changeset)

### Rust Output Sequence

```
1. CommandMetadata
2. TokenInfo                                          — after execute API call
3. StackEvents ("Previous Stack Events (max 10):")    — UNIQUE to exec-changeset
4. [watch_stack_operation_and_summarize]:
   4a. StackDefinition
   4b. NewStackEvents (live loop)
   4c. OperationComplete
   4d. StackContents
   4e. FinalCommandSummary
```

Expected sections: `["command_metadata", "stack_definition", "stack_events", "live_stack_events", "stack_contents"]`

**Key**: exec-changeset is the ONLY command that renders previous StackEvents between
TokenInfo and live events. This is because the user needs to see what happened before
the changeset execution started.

### Haskell Output Sequence (Current)

```
1. OdNewStackEvents (loop) — during pollForCompletion
```

### Missing in Haskell

| # | Missing | Severity |
|---|---------|----------|
| 1 | CommandMetadata | HIGH |
| 2 | TokenInfo | MEDIUM |
| 3 | StackEvents (previous) | HIGH — unique to this command, critical for context |
| 4 | StackDefinition | HIGH |
| 5 | StackContents after polling | HIGH — currently not emitted |
| 6 | OperationComplete | LOW |
| 7 | FinalCommandSummary | MEDIUM |

### Fix Plan

1. After executing changeset, before polling:
   - Fetch previous events via `fetchStackEvents` + `buildEventsDisplay`
   - Emit `OdStackEvents` with title "Previous Stack Events (max 10):"
2. After polling completes, emit `OdStackContents`
3. This is critical for the changeset workflow — users need to see previous state

---

## Changeset Console URL Pattern

Rust uses URL-encoded ARNs for changeset console URLs (different from stack info URLs):

```rust
let encoded_stack_arn = urlencoding::encode(stack_arn);
let encoded_changeset_arn = urlencoding::encode(changeset_arn);
let console_url = format!(
    "https://{region}.console.aws.amazon.com/cloudformation/home?region={region}#/changeset/detail?stackId={encoded_stack_arn}&changeSetId={encoded_changeset_arn}"
);
```

Note: Stack info URLs do NOT encode (see describe-stack fix). Changeset URLs DO encode.

### Relevant Code

- **Rust create-changeset**: `~/src/iidy/src/cfn/create_changeset.rs` lines 13-58
- **Rust exec-changeset**: `~/src/iidy/src/cfn/exec_changeset.rs` lines 15-132
- **Rust changeset_operations**: `~/src/iidy/src/cfn/changeset_operations.rs` lines 373-391 (URL)
- **Haskell**: `src/Iidy/Cfn/Operations/Changeset.hs` lines 87-177
