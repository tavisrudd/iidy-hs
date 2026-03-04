# HLint: Use join

**Count:** 1 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cfn/Operations/DescribeStack.hs` | 173:41 | `Map.lookup (seEventId e) durMap >>= id` | `Control.Monad.join (Map.lookup (seEventId e) durMap)` |
