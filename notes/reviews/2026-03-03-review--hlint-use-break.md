# HLint: Use break

**Count:** 1 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cli/Help.hs` | 607:26 | `span (not . Char.isSpace)` | `break Char.isSpace` |
