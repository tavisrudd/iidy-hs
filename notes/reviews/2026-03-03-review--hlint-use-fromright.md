# HLint: Use fromRight

**Count:** 4 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Cfn/Operations/TemplateApproval.hs` | 159:36 | `either (const "") id` | `fromRight ""` |
| `src/Iidy/Params/Review.hs` | 55:26 | `either (const "(not set)") id` | `fromRight "(not set)"` |
| `src/Iidy/Yaml/Imports/ContentParsing.hs` | 97:3 | `either (const (String val)) id` | `fromRight (String val)` |
| `src/Iidy/Yaml/Imports/ContentParsing.hs` | 99:3 | `either (const (String val)) id` | `fromRight (String val)` |
