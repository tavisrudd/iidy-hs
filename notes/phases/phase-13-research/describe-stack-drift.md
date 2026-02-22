# describe-stack-drift: Output Sequencing Analysis

## Rust Output Sequence

```
1. StackDefinition                              — stack details shown first
2. StatusUpdate("Checking for stack drift...")   — conditional: only if needs drift check
3. [drift detection polling loop, 3s intervals]
4. StackDrift                                   — drift results (or "no drift detected")
```

Expected sections: `["stack_drift"]`
No CommandMetadata, no FinalCommandSummary.

### Paths

**Drift detected**: Steps 1-4, shows drifted resources.
**No drift**: Steps 1-4, shows "No drift detected" message.
**Already has recent detection**: Steps 1, 4 (skip polling).

## Haskell Output Sequence (Current)

```
(no OutputData — returns Either Text Text, printed directly in Main.hs)
Main.hs line 156: TIO.putStrLn $ "Drift detection initiated: " <> did'
```

### Missing in Haskell

| # | Missing | Severity |
|---|---------|----------|
| 1 | StackDefinition | HIGH — no stack details shown |
| 2 | StatusUpdate during polling | MEDIUM — no "Checking for drift..." message |
| 3 | Actual drift results (StackDrift) | **CRITICAL** — only shows detection ID, not results |
| 4 | Drift polling to completion | **CRITICAL** — Rust polls until complete, Haskell returns immediately |

### Fix Plan

The Haskell version only initiates drift detection and returns the detection ID.
The Rust version initiates, polls for completion, then shows actual drift results.

1. After initiating detection, poll `DescribeStackDriftDetectionStatus` until complete
2. Then call `DescribeStackResourceDrifts` to get actual drift details
3. Construct `StackDrift` and emit via OutputData
4. Show StackDefinition before drift results

This is a significant implementation gap — the Haskell version is incomplete.

### Relevant Code

- **Rust**: `~/src/iidy/src/cfn/describe_stack_drift.rs` lines 14-109
- **Haskell**: `src/Iidy/Cfn/Operations/DescribeStackDrift.hs` (42 lines — only initiates)
