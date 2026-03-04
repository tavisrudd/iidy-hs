# HLint: Avoid lambda

**Count:** 8 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cfn/Operations/ConvertStack.hs` | 212:29 | `\ v -> emitItem doSort indent currentKey v` | `emitItem doSort indent currentKey` |
| `src/Iidy/Cfn/Operations/ConvertStack.hs` | 396:43 | `(\ c -> "  - " <> c)` | `("  - " <>)` |
| `src/Iidy/Cfn/Operations/ConvertStack.hs` | 400:47 | `(\ a -> "  - " <> a)` | `("  - " <>)` |
| `src/Iidy/Cfn/Operations/DescribeStack.hs` | 234:29 | `\ info -> emit (OdOperationComplete info)` | `emit . OdOperationComplete` |
| `src/Iidy/Cfn/Operations/ListStacks.hs` | 61:26 | `(\ f -> "tag:" <> f)` | `("tag:" <>)` |
| `src/Iidy/Cfn/Operations/WatchStack.hs` | 78:42 | `\ info -> emit (OdInactivityTimeout info)` | `emit . OdInactivityTimeout` |
| `src/Iidy/Yaml/JMESPath.hs` | 334:32 | `\ item -> isTruthy (evalJExpr cond item)` | `isTruthy . evalJExpr cond` |
| `src/Iidy/Yaml/Errors/Conversion/LineSearch.hs` | 198:22 | `\ ln -> maybe [] (: []) (findTag ln)` | `maybe [] (: []) . findTag` |
