# HLint: Use when

**Count:** 6 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cfn/Operations/DescribeStackDrift.hs` | 65:7 | `if needsCheck then     do now <- getCurrentTime        emit ...` | `Control.Monad.when needsCheck   $ do now <- getCurrentTime  ...` |
| `src/Iidy/Cfn/Operations/DescribeStackDrift.hs` | 80:11 | `if not completed then     do let timeoutMins              = ...` | `Control.Monad.when (not completed)   $ do let timeoutMins   ...` |
| `src/Iidy/Yaml/Resolution/Resolver.hs` | 818:3 | `if Set.member templateName (tcActiveExpansions ctx) then    ...` | `Control.Monad.when   (Set.member templateName (tcActiveExpan...` |
| `app/Main.hs` | 393:7 | `if emitsCommandMetadata operation then     do meta <- constr...` | `Control.Monad.when (emitsCommandMetadata operation)   $ do m...` |
| `app/Main.hs` | 403:7 | `if emitsCommandMetadata operation then     do elapsed <- ctx...` | `Control.Monad.when (emitsCommandMetadata operation)   $ do e...` |
| `test/Test/TemplateDiffTest.hs` | 174:3 | `if needle `T.isInfixOf` haystack then     fail       $ "Expe...` | `Control.Monad.when (needle `T.isInfixOf` haystack)   $ fail ...` |
