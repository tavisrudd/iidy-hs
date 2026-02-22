# list-stacks: Output Sequencing Analysis

## Rust Output Sequence

```
1. StackList (single output)
```

Expected sections: `["stack_list"]`
No CommandMetadata, no FinalCommandSummary.

## Haskell Output Sequence (Current)

```
1. OdStackList display (single output)
```

## Assessment

**Rendering is correct** — list-stacks was already verified in live testing
(line 168 of test file shows correct output with `--region us-west-2`).

The only issue found was the **region bug** (13.6) which affects ALL commands,
not list-stacks specifically. When `--region` is not specified and `$AWS_REGION`
is set, the wrong region is used. See `cross-cutting.md`.

### Relevant Code

- **Rust**: `~/src/iidy/src/cfn/list_stacks.rs`
- **Haskell**: `src/Iidy/Cfn/Operations/ListStacks.hs`
