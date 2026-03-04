# HLint: Use unless

**Count:** 5 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cfn/StackOperations.hs` | 296:9 | `when (not (null newEvents))` | `unless (null newEvents)` |
| `src/Iidy/Cfn/Operations/WatchStack.hs` | 77:17 | `when (not (null fresh))` | `unless (null fresh)` |
| `test/Test/IntegrationTest.hs` | 54:9 | `when (not (null failures))` | `unless (null failures)` |
| `test/Test/IntegrationTest.hs` | 66:9 | `when (not (null failures))` | `unless (null failures)` |
| `test/Test/IntegrationTest.hs` | 162:9 | `when (not (null failures))` | `unless (null failures)` |
