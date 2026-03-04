# HLint: Use maybeToList

**Count:** 3 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cli/Help.hs` | 501:17 | `maybe [] (: [])` | `maybeToList` |
| `src/Iidy/Yaml/CustomResources/Expansion.hs` | 110:33 | `maybe [] (: [])` | `maybeToList` |
| `src/Iidy/Yaml/Errors/Conversion/LineSearch.hs` | 198:29 | `maybe [] (: [])` | `maybeToList` |
