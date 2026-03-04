# HLint: Eta reduce

**Count:** 15 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cfn/TemplateLoader.hs` | 189:1 | `hasImportsKey t = T.isInfixOf "$imports:" t` | `hasImportsKey = T.isInfixOf "$imports:"` |
| `src/Iidy/Cfn/Operations/ConvertStack.hs` | 237:5 | `needsKeyQuoting t   = T.any       (`elem`        [':' :: Cha...` | `needsKeyQuoting   = T.any       (`elem`        [':' :: Char,...` |
| `src/Iidy/Cfn/Operations/ConvertStack.hs` | 309:5 | `hasControlChars t = T.any (< ' ') t` | `hasControlChars = T.any (< ' ')` |
| `src/Iidy/Cli/Help.hs` | 107:1 | `headingLine useColor label   = applyColor useColor headingCo...` | `headingLine useColor = applyColor useColor headingColorCode` |
| `src/Iidy/Output/Spinner.hs` | 88:1 | `spinnerSetMessage sp msg = atomicWriteIORef (spMessage sp) m...` | `spinnerSetMessage sp = atomicWriteIORef (spMessage sp)` |
| `src/Iidy/Output/Renderers/Interactive/Types.hs` | 342:1 | `formatSectionLabel r text = colorize (th r) (thMuted (th r))...` | `formatSectionLabel r = colorize (th r) (thMuted (th r))` |
| `src/Iidy/Yaml/Emitter.hs` | 18:1 | `emitYaml val = emitValue 0 True val` | `emitYaml = emitValue 0 True` |
| `src/Iidy/Yaml/Parser.hs` | 195:1 | `childrenEndPos startP metas   = List.foldl' (\ _ x -> smEnd ...` | `childrenEndPos = List.foldl' (\ _ x -> smEnd x)` |
| `src/Iidy/Yaml/Errors/Conversion.hs` | 227:1 | `classifyMessage source loc msg = classifyMessage' allLines l...` | `classifyMessage source = classifyMessage' allLines` |
| `src/Iidy/Yaml/Errors/Conversion/LineSearch.hs` | 156:1 | `findAllSubstring needle haystack = go 0 haystack` | `findAllSubstring needle = go 0` |
| `src/Iidy/Yaml/Imports/Loaders/File.hs` | 211:1 | `isAbsolutePath t = T.isPrefixOf "/" t` | `isAbsolutePath = T.isPrefixOf "/"` |
| `src/Iidy/Yaml/Resolution/Resolver.hs` | 908:1 | `imapMaybeM f xs = go 0 xs` | `imapMaybeM f = go 0` |
| `test/Test/ErrorContentTest.hs` | 50:1 | `assertContainsAll label output expected   = mapM_       (\ s...` | `assertContainsAll label output   = mapM_       (\ s         ...` |
| `test/Test/ParamsClientTest.hs` | 111:1 | `mkParamFull name pType val ver   = SSMP.newParameter name pT...` | `mkParamFull = SSMP.newParameter` |
| `test/Test/StackOpsConverterTest.hs` | 56:13 | `mkRes st = SR.newStackResource "R" "AWS::EC2::Instance" epoc...` | `mkRes = SR.newStackResource "R" "AWS::EC2::Instance" epoch` |
