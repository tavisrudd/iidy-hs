# get-stack-template: Output Sequencing Analysis

## Rust Output Sequence

```
1. StackTemplate (single output — stderr lines + template body to stdout)
```

Expected sections: `[]` (bypasses section system entirely)
No CommandMetadata, no FinalCommandSummary.

The renderer writes stderr_lines to stderr and template_body to stdout.

## Haskell Output Sequence (Current)

```
(no OutputData — returns Either Text Text, printed directly in Main.hs)
Main.hs line 171: TIO.putStrLn tpl
```

### Assessment

**Functionally correct** — template body goes to stdout in both versions.
The Rust version additionally supports stderr diagnostic lines, which the Haskell
version doesn't generate.

| # | Missing | Severity |
|---|---------|----------|
| 1 | Rendering via StackTemplate OutputData | LOW — output is equivalent |

No action needed unless stderr diagnostics are required.

### Relevant Code

- **Rust**: `~/src/iidy/src/cfn/get_stack_template.rs`
- **Haskell**: `src/Iidy/Cfn/Operations/GetStackTemplate.hs`
