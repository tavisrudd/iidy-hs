# HLint: Replace case with fromMaybe

**Count:** 3 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Explain.hs` | 52:16 | `case T.stripPrefix "ERR_" upper of   Just d -> d   Nothing -...` | `Data.Maybe.fromMaybe upper (T.stripPrefix "ERR_" upper)` |
| `src/Iidy/Cfn/Status.hs` | 131:12 | `case fromText (CF.fromStackStatus other) of   Just s -> s   ...` | `Data.Maybe.fromMaybe   CreateFailed (fromText (CF.fromStackS...` |
| `src/Iidy/Cfn/Status.hs` | 161:12 | `case fromText (CF.fromResourceStatus other) of   Just s -> s...` | `Data.Maybe.fromMaybe   CreateFailed (fromText (CF.fromResour...` |
