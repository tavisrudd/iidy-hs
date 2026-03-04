# HLint: Use fmap

**Count:** 1 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Yaml/Imports/Loaders/File.hs` | 134:23 | `\ f -> sha256Bytes <$> BS.readFile f` | `fmap sha256Bytes . BS.readFile` |
