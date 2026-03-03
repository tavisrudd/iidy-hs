# lint-template: Output Sequencing Analysis

## Rust Output Sequence

```
1. TemplateValidation (single output — errors + warnings)
```

No CommandMetadata, no FinalCommandSummary.
Expected sections: `["template_validation"]`

The renderer for TemplateValidation prints:
- Validation errors with red X marks
- Validation warnings with warning symbols
- "Template validation passed" if clean

## Haskell Output Sequence (Current)

```
(no OutputData — direct stdout via putStrLn)
Line 43: putStrLn "Warning: Template exceeds 51200 bytes; skipping API validation"
Line 52: putStrLn $ "Template validation failed: " <> show e
```

### Missing in Haskell

| # | Missing | Severity |
|---|---------|----------|
| 1 | Rendering via TemplateValidation OutputData | MEDIUM — no styled error/warning output |
| 2 | Individual error/warning breakdown | MEDIUM — just shows raw exception |
| 3 | Validation warnings (separate from errors) | LOW |

### Fix Plan

1. Parse validation response for errors and warnings (Rust extracts these from API response)
2. Construct `TemplateValidation` and emit via OutputData
3. The renderer (`renderTemplateValidation` at Interactive.hs line 789) already handles this

### Relevant Code

- **Rust**: `~/src/iidy/src/cfn/lint_template.rs` lines 11-40
- **Haskell**: `src/Iidy/Cfn/Operations/LintTemplate.hs` lines 28-55
- **Renderer**: `src/Iidy/Output/Renderers/Interactive.hs` line 789
