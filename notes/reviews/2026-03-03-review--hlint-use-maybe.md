# HLint: Use maybe

**Count:** 8 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cfn/StackOperations.hs` | 189:19 | `map convertResource (fromMaybe [] resourcesResp.stackResourc...` | `maybe [] (map convertResource) resourcesResp.stackResources` |
| `src/Iidy/Cfn/Operations/Changeset.hs` | 307:30 | `map convertDetail (fromMaybe [] rc.details)` | `maybe [] (map convertDetail) rc.details` |
| `src/Iidy/Cfn/Operations/Changeset.hs` | 315:20 | `fromMaybe "" (fmap CF.fromResourceAttribute t.attribute)` | `maybe "" CF.fromResourceAttribute t.attribute` |
| `src/Iidy/Cfn/Operations/DescribeStack.hs` | 92:22 | `map (.fromCapability) (fromMaybe [] s.capabilities)` | `maybe [] (map ((.fromCapability))) s.capabilities` |
| `src/Iidy/Cfn/Operations/DescribeStackDrift.hs` | 202:29 | `map convertPropDiff (fromMaybe [] d.propertyDifferences)` | `maybe [] (map convertPropDiff) d.propertyDifferences` |
| `src/Iidy/Yaml/Imports/Loaders/Cfn.hs` | 255:23 | `map   (\ o -> (fromMaybe "" o.outputKey, fromMaybe "" o.outp...` | `maybe   []   (map      (\ o -> (fromMaybe "" o.outputKey, fr...` |
| `src/Iidy/Yaml/Imports/Loaders/Cfn.hs` | 257:23 | `map   (\ p      -> (fromMaybe "" p.parameterKey, fromMaybe "...` | `maybe   []   (map      (\ p         -> (fromMaybe "" p.param...` |
| `src/Iidy/Yaml/Imports/Loaders/Cfn.hs` | 259:23 | `map (\ t -> (t.key, t.value)) (fromMaybe [] stack.tags)` | `maybe [] (map (\ t -> (t.key, t.value))) stack.tags` |
