# HLint: Use newtype instead of data

**Count:** 6 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cli.hs` | 291:1 | `data LintTemplateArgs   = LintTemplateArgs {ltaArgsfile :: !...` | `newtype LintTemplateArgs   = LintTemplateArgs {ltaArgsfile :...` |
| `src/Iidy/Output/Types.hs` | 376:1 | `data StackDrift   = StackDrift {sdrDriftedResources :: ![Dri...` | `newtype StackDrift   = StackDrift {sdrDriftedResources :: [D...` |
| `src/Iidy/Yaml/Handlebars/Engine.hs` | 33:1 | `data InterpolateError   = InterpolateError !Text   deriving ...` | `newtype InterpolateError   = InterpolateError Text   derivin...` |
| `src/Iidy/Yaml/Handlebars/Engine.hs` | 36:1 | `data Template   = Template [TemplatePart]   deriving stock (...` | `newtype Template   = Template [TemplatePart]   deriving stoc...` |
| `src/Iidy/Yaml/Imports/Loaders/Http.hs` | 36:1 | `data HttpSizeLimitExceeded   = HttpSizeLimitExceeded Int   d...` | `newtype HttpSizeLimitExceeded   = HttpSizeLimitExceeded Int ...` |
| `src/Iidy/Yaml/Imports/Loaders/S3.hs` | 67:1 | `data S3SizeLimitExceeded   = S3SizeLimitExceeded Int   deriv...` | `newtype S3SizeLimitExceeded   = S3SizeLimitExceeded Int   de...` |
