# convert-stack-to-iidy: Output Sequencing Analysis

## Rust Output Sequence

```
(no OutputData — direct stderr writes)
eprintln!("Wrote {policy_path}")
eprintln!("Wrote {original_path}")
eprintln!("Wrote {cfn_template_path}")
eprintln!("Writing SSM parameter: {name}")   — per parameter, if moveParamsToSsm
eprintln!("Wrote {stack_args_path}")
```

Expected sections: `[]` (bypasses renderer system)
No CommandMetadata, no FinalCommandSummary.

## Haskell Output Sequence (Current)

```
(no OutputData — direct stderr writes via hPutStrLn stderr)
Same pattern as Rust: file write messages to stderr.
```

## Assessment

**Both versions use direct stderr I/O.** This is correct — convert-stack-to-iidy
is a file generation command that writes to disk, not a display command.

No divergence expected. No action needed.

### Relevant Code

- **Rust**: `~/src/iidy/src/cfn/convert_stack_to_iidy.rs` lines 384-497
- **Haskell**: `src/Iidy/Cfn/Operations/ConvertStack.hs`
