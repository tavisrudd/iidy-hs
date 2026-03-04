# HLint: Use fromMaybe

**Count:** 12 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Yaml/JMESPath.hs` | 304:19 | `maybe Null id` | `Data.Maybe.fromMaybe Null` |
| `src/Iidy/Yaml/Imports/Loaders/Cfn.hs` | 75:18 | `maybe location id` | `fromMaybe location` |
| `src/Iidy/Yaml/Imports/Loaders/Env.hs` | 15:18 | `maybe location id` | `Data.Maybe.fromMaybe location` |
| `src/Iidy/Yaml/Imports/Loaders/File.hs` | 208:23 | `maybe loc id` | `Data.Maybe.fromMaybe loc` |
| `src/Iidy/Yaml/Imports/Loaders/Git.hs` | 31:18 | `maybe location id` | `Data.Maybe.fromMaybe location` |
| `src/Iidy/Yaml/Imports/Loaders/Http.hs` | 125:18 | `maybe url id` | `Data.Maybe.fromMaybe url` |
| `src/Iidy/Yaml/Imports/Loaders/Http.hs` | 126:19 | `maybe noScheme id` | `Data.Maybe.fromMaybe noScheme` |
| `src/Iidy/Yaml/Imports/Loaders/Random.hs` | 15:18 | `maybe location id` | `Data.Maybe.fromMaybe location` |
| `src/Iidy/Yaml/Imports/Loaders/S3.hs` | 35:13 | `maybe location id` | `Data.Maybe.fromMaybe location` |
| `src/Iidy/Yaml/Imports/Loaders/S3.hs` | 111:24 | `maybe uri id` | `Data.Maybe.fromMaybe uri` |
| `src/Iidy/Yaml/Imports/Loaders/Ssm.hs` | 129:18 | `maybe location id` | `fromMaybe location` |
| `app/Main.hs` | 169:23 | `maybe "" id` | `Data.Maybe.fromMaybe ""` |
