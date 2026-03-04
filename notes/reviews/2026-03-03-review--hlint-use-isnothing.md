# HLint: Use isNothing

**Count:** 2 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cli/Help.hs` | 104:34 | `not (isJust noColor)` | `isNothing noColor` |
| `test/Test/GlobalConfigTest.hs` | 129:39 | `saNotificationArns sa == Nothing` | `isNothing (saNotificationArns sa)` |
