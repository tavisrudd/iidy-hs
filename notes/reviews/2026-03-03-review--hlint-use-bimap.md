# HLint: Use bimap

**Count:** 1 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Yaml/CustomResources/Expansion.hs` | 63:33 | `\ (k, v) -> (prefix <> k, rewriteRefs prefix allGlobals v)` | `Data.Bifunctor.bimap ((<>) prefix) (rewriteRefs prefix allGl...` |
