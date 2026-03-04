# HLint: Use catMaybes

**Count:** 3 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `test/Test/IntegrationTest.hs` | 53:24 | `[f \| Just f <- results]` | `Data.Maybe.catMaybes results` |
| `test/Test/IntegrationTest.hs` | 65:24 | `[f \| Just f <- results]` | `Data.Maybe.catMaybes results` |
| `test/Test/IntegrationTest.hs` | 161:24 | `[f \| Just f <- results]` | `Data.Maybe.catMaybes results` |
