# HLint: Use first

**Count:** 1 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cli/Help.hs` | 132:22 | `\ (name, desc) -> (formatEntryName name, desc)` | `Data.Bifunctor.first formatEntryName` |
