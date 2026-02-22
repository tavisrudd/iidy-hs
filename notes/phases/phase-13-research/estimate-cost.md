# estimate-cost: Output Sequencing Analysis

## Rust Output Sequence

```
1. CostEstimate (single output — contains URL)
```

No CommandMetadata, no FinalCommandSummary.
Expected sections: `["command_metadata", "cost_estimate"]` (but CommandMetadata not actually rendered)

The renderer for CostEstimate prints:
```
Stack cost estimator: <url>
```

## Haskell Output Sequence (Current)

```
(no OutputData — returns Either Text Text, printed directly in Main.hs)
Main.hs line 111: TIO.putStrLn url
```

### Missing in Haskell

| # | Missing | Severity |
|---|---------|----------|
| 1 | Rendering via CostEstimate OutputData | LOW — output is similar but bypasses renderer |

### Fix Plan

Change to emit `OdCostEstimate` instead of returning raw URL text. The renderer
(`renderCostEstimate` at Interactive.hs line 769) already handles this correctly
with styled output.

Minor change: have estimateCost return `[OutputData]` or accept `emit` callback.

### Relevant Code

- **Rust**: `~/src/iidy/src/cfn/estimate_cost.rs` lines 13-85
- **Haskell**: `src/Iidy/Cfn/Operations/EstimateCost.hs` lines 33-53
- **Renderer**: `src/Iidy/Output/Renderers/Interactive.hs` line 769
