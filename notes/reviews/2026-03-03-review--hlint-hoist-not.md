# HLint: Hoist not

**Count:** 6 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cli/Help.hs` | 589:29 | `any (not . Char.isSpace)` | `(not . all Char.isSpace)` |
| `src/Iidy/Cli/Help.hs` | 589:29 | `any (not . Char.isSpace) (drop 2 line)` | `not (all Char.isSpace (drop 2 line))` |
| `src/Iidy/Output/Renderers/Interactive/Sections.hs` | 231:22 | `any (not . null . seiImportingStacks)` | `(not . all (null . seiImportingStacks))` |
| `src/Iidy/Output/Renderers/Interactive/Sections.hs` | 231:22 | `any (not . null . seiImportingStacks) (scExports contents)` | `not (all (null . seiImportingStacks) (scExports contents))` |
| `test/Test/ImportLoaderTest.hs` | 132:40 | `all (not . T.null)` | `(not . any T.null)` |
| `test/Test/ImportLoaderTest.hs` | 132:40 | `all (not . T.null) parts` | `not (any T.null parts)` |
