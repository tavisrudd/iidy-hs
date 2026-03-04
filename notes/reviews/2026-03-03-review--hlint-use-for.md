# HLint: Use for_

**Count:** 4 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Output/Renderers/Interactive/Sections.hs` | 287:3 | `case crMessage res of   Just msg -> rPutStrLn r msg   Nothin...` | `Data.Foldable.for_ (crMessage res) (rPutStrLn r)` |
| `src/Iidy/Output/Renderers/Interactive/Types.hs` | 238:3 | `case mTid of   Just tid -> killThread tid   Nothing -> pure ...` | `Data.Foldable.for_ mTid killThread` |
| `src/Iidy/Output/Renderers/Interactive/Types.hs` | 244:3 | `case mSp of   Just sp -> spinnerFinishAndClear sp   Nothing ...` | `Data.Foldable.for_ mSp spinnerFinishAndClear` |
| `src/Iidy/Output/Renderers/Interactive/Types.hs` | 297:3 | `case mTid of   Just tid -> killThread tid   Nothing -> pure ...` | `Data.Foldable.for_ mTid killThread` |
