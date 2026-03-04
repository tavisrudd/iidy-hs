# HLint: Use ?~

**Count:** 23 findings

| File | Location | From | Why not |
|------|----------|------|---------|
| `test/Test/ParamsClientTest.hs` | 137:17 | `SSMP.parameter_arn   .~ Just "arn:aws:ssm:us-east-1:123:para...` | `(SSMP.parameter_arn    ?~ "arn:aws:ssm:us-east-1:123:paramet...` |
| `test/Test/ParamsClientTest.hs` | 138:17 | `SSMP.parameter_dataType .~ Just "text"` | `(SSMP.parameter_dataType ?~ "text")` |
| `test/Test/ParamsClientTest.hs` | 178:17 | `SSMP.parameter_arn   .~ Just "arn:aws:ssm:us-east-1:123:para...` | `(SSMP.parameter_arn ?~ "arn:aws:ssm:us-east-1:123:parameter/...` |
| `test/Test/ParamsClientTest.hs` | 237:7 | `SSMPH.parameterHistory_name .~ Just "/myapp/db-pass"` | `(SSMPH.parameterHistory_name ?~ "/myapp/db-pass")` |
| `test/Test/ParamsClientTest.hs` | 238:7 | `SSMPH.parameterHistory_type   .~ Just SSMPT.ParameterType_Se...` | `(SSMPH.parameterHistory_type ?~ SSMPT.ParameterType_SecureSt...` |
| `test/Test/ParamsClientTest.hs` | 239:7 | `SSMPH.parameterHistory_keyId .~ Just "alias/ssm/myapp/"` | `(SSMPH.parameterHistory_keyId ?~ "alias/ssm/myapp/")` |
| `test/Test/ParamsClientTest.hs` | 240:7 | `SSMPH.parameterHistory_lastModifiedUser   .~ Just "arn:aws:i...` | `(SSMPH.parameterHistory_lastModifiedUser    ?~ "arn:aws:iam:...` |
| `test/Test/ParamsClientTest.hs` | 241:7 | `SSMPH.parameterHistory_description .~ Just "DB password"` | `(SSMPH.parameterHistory_description ?~ "DB password")` |
| `test/Test/ParamsClientTest.hs` | 242:7 | `SSMPH.parameterHistory_value .~ Just "old-secret"` | `(SSMPH.parameterHistory_value ?~ "old-secret")` |
| `test/Test/ParamsClientTest.hs` | 243:7 | `SSMPH.parameterHistory_version .~ Just 2` | `(SSMPH.parameterHistory_version ?~ 2)` |
| `test/Test/ParamsClientTest.hs` | 244:7 | `SSMPH.parameterHistory_dataType .~ Just "text"` | `(SSMPH.parameterHistory_dataType ?~ "text")` |
| `test/Test/ParamsClientTest.hs` | 262:17 | `SSMPH.parameterHistory_name .~ Just "/test"` | `(SSMPH.parameterHistory_name ?~ "/test")` |
| `test/Test/ParamsClientTest.hs` | 263:17 | `SSMPH.parameterHistory_value .~ Just "val"` | `(SSMPH.parameterHistory_value ?~ "val")` |
| `test/Test/ParamsClientTest.hs` | 264:17 | `SSMPH.parameterHistory_version .~ Just 1` | `(SSMPH.parameterHistory_version ?~ 1)` |
| `test/Test/ParamsClientTest.hs` | 279:17 | `SSMPH.parameterHistory_name .~ Just "/test"` | `(SSMPH.parameterHistory_name ?~ "/test")` |
| `test/Test/ParamsClientTest.hs` | 280:17 | `SSMPH.parameterHistory_value .~ Just "val"` | `(SSMPH.parameterHistory_value ?~ "val")` |
| `test/Test/ParamsClientTest.hs` | 281:17 | `SSMPH.parameterHistory_version .~ Just 1` | `(SSMPH.parameterHistory_version ?~ 1)` |
| `test/Test/ParamsClientTest.hs` | 287:17 | `SSMPH.parameterHistory_name .~ Just "/test"` | `(SSMPH.parameterHistory_name ?~ "/test")` |
| `test/Test/ParamsClientTest.hs` | 288:17 | `SSMPH.parameterHistory_value .~ Just "val"` | `(SSMPH.parameterHistory_value ?~ "val")` |
| `test/Test/ParamsClientTest.hs` | 289:17 | `SSMPH.parameterHistory_version .~ Just 1` | `(SSMPH.parameterHistory_version ?~ 1)` |
| `test/Test/ParamsClientTest.hs` | 374:25 | `SSMPH.parameterHistory_name .~ Just "/myapp/db-pass"` | `(SSMPH.parameterHistory_name ?~ "/myapp/db-pass")` |
| `test/Test/ParamsClientTest.hs` | 375:25 | `SSMPH.parameterHistory_value .~ Just "older-secret"` | `(SSMPH.parameterHistory_value ?~ "older-secret")` |
| `test/Test/ParamsClientTest.hs` | 376:25 | `SSMPH.parameterHistory_version .~ Just 1` | `(SSMPH.parameterHistory_version ?~ 1)` |
