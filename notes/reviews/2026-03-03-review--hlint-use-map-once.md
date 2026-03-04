# HLint: Use map once

**Count:** 1 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cli/Help.hs` | 82:32 | `map (map Char.toLower) (map fst normalized)` | `map (map Char.toLower . fst) normalized` |
