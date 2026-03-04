# HLint: Replace case with maybe

**Count:** 2 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Aws/Timing.hs` | 74:7 | `case r2 of   Just t -> pure t   Nothing -> getCurrentTime` | `maybe getCurrentTime pure r2` |
| `app/Main.hs` | 151:21 | `case ccsChangesetName args of   Just name -> pure name   Not...` | `maybe generateDashedName pure (ccsChangesetName args)` |
