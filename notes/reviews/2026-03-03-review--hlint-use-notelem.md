# HLint: Use notElem

**Count:** 3 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Output/Renderers/Interactive/Types.hs` | 412:48 | `not (k `elem` envKeys)` | `notElem k envKeys` |
| `src/Iidy/Yaml/Emitter.hs` | 106:22 | `not (c `elem` ("-?:,[]{}#&*!\|>'\"%@`" :: [Char]))` | `notElem c ("-?:,[]{}#&*!\|>'\"%@`" :: [Char])` |
| `test/Test/CfnYamlEmitterTest.hs` | 61:48 | `not ('e' `elem` T.unpack result)` | `notElem 'e' (T.unpack result)` |
