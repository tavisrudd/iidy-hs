# create-or-update: Output Sequencing Analysis

## Rust Output Sequence — 5 Distinct Paths

This is the most complex command in iidy. The Rust version has 5 paths based on
(stack exists?) x (--changeset flag?) x (changes detected?).

### Path 1: Stack Exists + No Changeset + Has Changes → Direct Update

```
1. CommandMetadata
2. StackChangeDetails(UpdateWithChanges)
3. TokenInfo
4. [watch_stack_operation_and_summarize]:
   4a. StackDefinition
   4b. NewStackEvents (loop)
   4c. OperationComplete
   4d. StackContents
   4e. FinalCommandSummary
```

### Path 2: Stack Exists + No Changeset + No Changes

```
1. CommandMetadata
2. StackChangeDetails(UpdateNoChanges)    — "No changes detected"
3. (early return, exit 0)
```

### Path 3: Stack Exists + Changeset

```
1. CommandMetadata
2. StackDefinition                        — shown before changeset
3. [create_changeset_comprehensive]       — spinner while creating
4. ChangeSetResult
5. ConfirmationPrompt (if not --yes)
6. [If confirmed → exec_changeset sequence]:
   6a. TokenInfo
   6b. StackEvents (previous)
   6c. NewStackEvents (live loop)
   6d. OperationComplete
   6e. StackContents
   6f. FinalCommandSummary
```

### Path 4: Stack Doesn't Exist + No Changeset → Direct Create

```
1. CommandMetadata
2. StackChangeDetails(Create)             — "Creating new stack"
3. TokenInfo
4. [watch_stack_operation_and_summarize]:
   4a. StackDefinition
   4b. NewStackEvents (loop)
   4c. OperationComplete
   4d. StackContents
   4e. FinalCommandSummary
```

### Path 5: Stack Doesn't Exist + Changeset → Changeset Create

```
1. CommandMetadata
2. [create_changeset_comprehensive]       — creates stack in REVIEW_IN_PROGRESS
3. StackDefinition                        — stack now exists
4. ChangeSetResult
5. ConfirmationPrompt (if not --yes)
6. [If confirmed → exec_changeset sequence]
```

Expected sections vary per path — see Rust renderer `setup_operation()`.

## Haskell Output Sequence (Current)

```
1. Check stackExists
2. If exists → delegates to updateStack → [OdNewStackEvents*, OdStackContents]
3. If not → delegates to createStack → [OdNewStackEvents*, OdStackContents?]
```

### Missing in Haskell

| # | Missing | Severity |
|---|---------|----------|
| 1 | CommandMetadata | HIGH |
| 2 | StackChangeDetails (all variants) | HIGH — no "Creating new stack" / "Updating" / "No changes" |
| 3 | TokenInfo | MEDIUM |
| 4 | StackDefinition before events | HIGH |
| 5 | **Changeset path entirely** | **CRITICAL** — `_useChangeset` param is ignored (line 42) |
| 6 | ConfirmationPrompt for changeset | HIGH |
| 7 | FinalCommandSummary | MEDIUM |
| 8 | OperationComplete | LOW |

### Fix Plan

1. Emit `OdStackChangeDetails` before delegating to create/update
2. **Changeset path**: substantial new code:
   - Stack exists + changeset: show definition, create changeset, show result, confirm, execute
   - Stack doesn't exist + changeset: create changeset (type=CREATE), show definition, confirm, execute
3. This depends on changeset creation and execution infrastructure being correct first

### Relevant Code

- **Rust**: `~/src/iidy/src/cfn/create_or_update.rs` lines 20-355
- **Haskell**: `src/Iidy/Cfn/Operations/CreateOrUpdate.hs` (52 lines — extremely thin)
- Comment on line 33: "The @useChangeset@ parameter is reserved for future --changeset support;
  the current implementation always uses the direct create/update path."
