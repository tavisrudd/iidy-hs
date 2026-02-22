# describe-stack: Output Sequencing Analysis

## Rust Output Sequence

### Normal Path

```
1. StackDefinition (show_times=true)            — fetched async
2. StackEvents ("Previous Stack Events (max N):")  — title includes event count from args
3. StackContents                                — resources, outputs, exports, current status
```

All three fetched in parallel, awaited in sequence.
Expected sections: `["stack_definition", "stack_events", "stack_contents"]`

No CommandMetadata, no FinalCommandSummary (read-only operation).

### Stack Not Found Path

The error propagates up and is handled by the output manager's error analysis
(`analyze_aws_error`), which constructs StackAbsentInfo with env/region/account/auth_arn.

## Haskell Output Sequence (Current)

### Normal Path

```
1. OdStackDefinition stackDef True
2. OdStackEvents eventsDisplay
3. OdStackContents contents
```

This is mostly correct! But:

### Stack Not Found Path

```
Left ("Stack not found: " <> stackName)  →  dieTxt in Main.hs  →  "iidy-hs: Stack not found: X"
```

Raw error message, no styled output.

## Issues Found in Live Testing

| # | Issue | Severity |
|---|-------|----------|
| 1 | Missing "Previous Stack Events" section heading | HIGH — renderStackEvents doesn't print sedTitle |
| 2 | Missing "Stack Resources:" section heading | HIGH — renderStackContents doesn't print heading |
| 3 | Console URL encodes slashes | MEDIUM — `T.replace "/" "%2F"` wrong for stack info URLs |
| 4 | Stack-not-found error formatting | HIGH — raw text vs styled StackAbsentInfo |

### Fix Plan

1. **Section headings**: In `renderStackEvents`, add `printSectionHeadingLn r (sedTitle evts)`.
   In `renderStackContents`, add `printSectionHeadingLn r "Stack Resources"` before resources.
2. **Console URL**: Remove `T.replace "/" "%2F"` in `buildConsoleUrl`.
3. **Stack not found**: Instead of `Left "Stack not found"`, call STS GetCallerIdentity
   and return `Right [OdError (ErrorInfo { eiErrorDetails = ErrorStackAbsent sai })]`.

### Relevant Code

- **Rust**: `~/src/iidy/src/cfn/describe_stack.rs` lines 10-90
- **Haskell**: `src/Iidy/Cfn/Operations/DescribeStack.hs` lines 39-55, 142-149
- **Renderer**: `src/Iidy/Output/Renderers/Interactive.hs` lines 392-435 (events), 437-504 (contents)
