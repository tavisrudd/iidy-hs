# HLint: Move mapMaybe

**Count:** 1 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cfn/StackOperations.hs` | 190:20 | `mapMaybe   convertChangeSetSummary   (concatMap (fromMaybe [...` | `concatMap   (mapMaybe convertChangeSetSummary . fromMaybe []...` |
