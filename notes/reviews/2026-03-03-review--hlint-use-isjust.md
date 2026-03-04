# HLint: Use isJust

**Count:** 12 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `test/Test/JsonRendererTest.hs` | 69:31 | `jsonLookup "event" val /= Nothing` | `Data.Maybe.isJust (jsonLookup "event" val)` |
| `test/Test/JsonRendererTest.hs` | 158:43 | `jsonLookup "drifted_resources" val /= Nothing` | `Data.Maybe.isJust (jsonLookup "drifted_resources" val)` |
| `test/Test/JsonRendererTest.hs` | 264:34 | `jsonLookup "data" v /= Nothing` | `Data.Maybe.isJust (jsonLookup "data" v)` |
| `test/Test/JsonRendererTest.hs` | 317:35 | `jsonLookup "resources" val /= Nothing` | `Data.Maybe.isJust (jsonLookup "resources" val)` |
| `test/Test/JsonRendererTest.hs` | 318:33 | `jsonLookup "outputs" val /= Nothing` | `Data.Maybe.isJust (jsonLookup "outputs" val)` |
| `test/Test/RendererOutputTest.hs` | 114:32 | `jsonLookup "stacks" val /= Nothing` | `Data.Maybe.isJust (jsonLookup "stacks" val)` |
| `test/Test/RendererOutputTest.hs` | 115:33 | `jsonLookup "filters_applied" val /= Nothing` | `Data.Maybe.isJust (jsonLookup "filters_applied" val)` |
| `test/Test/RendererOutputTest.hs` | 116:33 | `jsonLookup "columns" val /= Nothing` | `Data.Maybe.isJust (jsonLookup "columns" val)` |
| `test/Test/RendererOutputTest.hs` | 132:34 | `jsonLookup "data" v /= Nothing` | `Data.Maybe.isJust (jsonLookup "data" v)` |
| `test/Test/RequestBuilderTest.hs` | 46:41 | `result /= Nothing` | `Data.Maybe.isJust result` |
| `test/Test/RequestBuilderTest.hs` | 56:39 | `result /= Nothing` | `Data.Maybe.isJust result` |
| `test/Test/TimingTest.hs` | 111:34 | `parseNtpResponse   (BS.pack      (replicate 40 0         ++ ...` | `Data.Maybe.isJust   (parseNtpResponse      (BS.pack         ...` |
