# HLint: Avoid lambda using `infix`

**Count:** 3 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Params/Client.hs` | 443:47 | `(\ p -> p ^. SSMP.parameter_name)` | `(^. SSMP.parameter_name)` |
| `src/Iidy/Yaml/Parser.hs` | 436:30 | `(\ o -> o <> " (optional)")` | `(<> " (optional)")` |
| `src/Iidy/Yaml/Errors/Conversion/Guidance.hs` | 130:34 | `(\ p -> p `T.isPrefixOf` msg)` | `(`T.isPrefixOf` msg)` |
