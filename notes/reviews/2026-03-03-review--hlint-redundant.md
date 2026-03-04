# HLint: Redundant $

**Count:** 5 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Yaml/JMESPath.hs` | 151:27 | `JMESPathError   $ "JMESPath functions are not supported in i...` | `JMESPathError   "JMESPath functions are not supported in iid...` |
| `src/Iidy/Yaml/JMESPath.hs` | 250:39 | `JMESPathError   $ "JMESPath slice expressions are not suppor...` | `JMESPathError   "JMESPath slice expressions are not supporte...` |
| `src/Iidy/Yaml/JMESPath.hs` | 254:27 | `JMESPathError   $ "JMESPath slice expressions are not suppor...` | `JMESPathError   "JMESPath slice expressions are not supporte...` |
| `src/Iidy/Yaml/CustomResources/JsonSchema.hs` | 102:15 | `Left $ "Value does not match any of the expected types"` | `Left "Value does not match any of the expected types"` |
| `src/Iidy/Yaml/CustomResources/JsonSchema.hs` | 126:22 | `Left $ "Value not in enum"` | `Left "Value not in enum"` |
