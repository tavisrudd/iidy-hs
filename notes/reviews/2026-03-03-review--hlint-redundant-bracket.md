# HLint: Redundant bracket

**Count:** 14 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cfn/Operations/ListStacks.hs` | 107:37 | `(s.creationTime.fromTime)` | `s.creationTime.fromTime` |
| `src/Iidy/Cfn/Operations/TemplateApproval.hs` | 230:13 | `do let body = Amazonka.toBody (TE.encodeUtf8 content)       ...` | `do let body = Amazonka.toBody (TE.encodeUtf8 content)       ...` |
| `src/Iidy/Yaml/Parser.hs` | 362:26 | `("must be a mapping with 'items' and 'template' fields")` | `"must be a mapping with 'items' and 'template' fields"` |
| `src/Iidy/Yaml/Parser.hs` | 386:41 | `("'items' missing in !$mergeMap tag")` | `"'items' missing in !$mergeMap tag"` |
| `src/Iidy/Yaml/Parser.hs` | 387:41 | `("'template' missing in !$mergeMap tag")` | `"'template' missing in !$mergeMap tag"` |
| `src/Iidy/Yaml/Parser.hs` | 398:41 | `("'items' missing in !$mapValues tag")` | `"'items' missing in !$mapValues tag"` |
| `src/Iidy/Yaml/Parser.hs` | 399:41 | `("'template' missing in !$mapValues tag")` | `"'template' missing in !$mapValues tag"` |
| `src/Iidy/Yaml/Parser.hs` | 410:41 | `("'items' missing in !$groupBy tag")` | `"'items' missing in !$groupBy tag"` |
| `src/Iidy/Yaml/Parser.hs` | 411:41 | `("'key' missing in !$groupBy tag")` | `"'key' missing in !$groupBy tag"` |
| `src/Iidy/Yaml/Parser.hs` | 421:41 | `("'template' missing in !$expand tag")` | `"'template' missing in !$expand tag"` |
| `src/Iidy/Yaml/Parser.hs` | 422:41 | `("'params' missing in !$expand tag")` | `"'params' missing in !$expand tag"` |
| `src/Iidy/Yaml/CustomResources/JsonSchema.hs` | 169:5 | `(T.unpack s =~ T.unpack pat :: Bool)` | `  T.unpack s =~ T.unpack pat :: Bool` |
| `test/Test/DescribeStackTest.hs` | 184:21 | `(CF.newParameter)` | `CF.newParameter` |
| `test/Test/DescribeStackTest.hs` | 185:21 | `(CF.newParameter)` | `CF.newParameter` |
