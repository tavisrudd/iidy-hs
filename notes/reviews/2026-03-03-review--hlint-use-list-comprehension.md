# HLint: Use list comprehension

**Count:** 3 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `src/Iidy/Aws/Config.hs` | 131:16 | `if hasAccessKey && hasSecretKey then     [EnvironmentVariabl...` | `([EnvironmentVariablesStatic \| hasAccessKey && hasSecretKey...` |
| `src/Iidy/Cfn/Operations/ConvertStack.hs` | 383:11 | `if not (null ssmParamKeys) then     ["  ssmParams: 'ssm-path...` | `["  ssmParams: 'ssm-path:/{{environment}}/{{project}}/'" \| ...` |
| `src/Iidy/Cli/Help.hs` | 460:22 | `if hadOptions then ["[OPTIONS]"] else []` | `(["[OPTIONS]" \| hadOptions])` |
