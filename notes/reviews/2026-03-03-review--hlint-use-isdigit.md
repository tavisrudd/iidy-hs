# HLint: Use isDigit

**Count:** 6 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cfn/Operations/ConvertStack.hs` | 88:49 | `c >= '0' && c <= '9'` | `isDigit c` |
| `src/Iidy/Yaml/Handlebars/Helpers.hs` | 246:23 | `c >= '0' && c <= '9'` | `isDigit c` |
| `src/Iidy/Yaml/Imports/Loaders/File.hs` | 165:9 | `c >= '0' && c <= '9'` | `isDigit c` |
| `test/Test/FilehashTest.hs` | 187:17 | `c >= '0' && c <= '9'` | `isDigit c` |
| `test/Test/ImportLoaderTest.hs` | 231:17 | `c >= '0' && c <= '9'` | `isDigit c` |
| `test/Test/PropertyTest.hs` | 149:15 | `c >= '0' && c <= '9'` | `isDigit c` |
