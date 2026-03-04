# HLint: Use <$>

**Count:** 1 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cfn/StackArgsLoader.hs` | 208:3 | `fmap Object   $ foldM       (\ acc key -> resolveEnvMapField...` | `Object   <$>     foldM       (\ acc key -> resolveEnvMapFiel...` |
