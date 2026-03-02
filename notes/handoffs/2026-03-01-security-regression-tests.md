# Security Controls Regression Tests -- Test Addition

**Date**: 2026-03-01
**References**: Commit `fa767b3`, handoff `notes/handoffs/done/2026-03-01-security-review-fixes.md`

## Context

Commit `fa767b3` added three security controls (import trust gate, regex length
cap, HTTP timeout/max-size). Zero tests exist for any of these controls. This
task adds focused regression tests to prevent future regressions.

## What to Test

### A. Import trust gate (parseImportType + dispatcher enforcement)

The security model: imports from remote base locations (S3, HTTP, HTTPS) cannot
load local-only types (file, env, git, filehash, filehash-base64).

**Test parseImportType directly** (pure function, no IO needed):

| Case                                                | Expected                          |
|-----------------------------------------------------|-----------------------------------|
| `parseImportType "file:foo.yaml" "."`               | `Right ImportFile`                |
| `parseImportType "env:MY_VAR" "."`                  | `Right ImportEnv`                 |
| `parseImportType "file:foo.yaml" "s3://bucket/base"`| `Left (ImportError "...not allowed from remote...")` |
| `parseImportType "env:MY_VAR" "https://example.com"`| `Left (ImportError "...not allowed from remote...")` |
| `parseImportType "git:sha" "http://example.com"`    | `Left (ImportError "...not allowed from remote...")` |
| `parseImportType "filehash:f" "s3://bucket/base"`   | `Left (ImportError "...not allowed from remote...")` |
| `parseImportType "s3://bucket/k" "s3://bucket/base"`| `Right ImportS3` (remote→remote OK) |
| `parseImportType "http://x" "s3://bucket/base"`     | `Right ImportHttp` (remote→remote OK) |
| `parseImportType "ssm:/p" "https://example.com"`    | `Right ImportSsm` (remote→AWS OK) |
| `parseImportType "bogus:x" "."`                     | `Left (ImportError "Unknown...")`  |

**Test mkFullDispatcher** rejects forbidden combinations (IO, calls the actual dispatcher):

| Case                                                            | Expected |
|-----------------------------------------------------------------|----------|
| `mkFullDispatcher Nothing "file:foo.yaml" "s3://bucket/base"`  | `Left` with "not allowed" |
| `mkFullDispatcher Nothing "env:X" "https://example.com/base"`  | `Left` with "not allowed" |

### B. Regex pattern length cap

**Test validatePattern (JsonSchema.hs)**:

| Case                                   | Expected                          |
|----------------------------------------|-----------------------------------|
| Pattern of length 1024, value matches  | `Right ()`                        |
| Pattern of length 1025                 | `Left "...exceeds maximum length..."` |
| Normal short pattern, value matches    | `Right ()`                        |
| Normal short pattern, value fails      | `Left "...does not match..."` |

**Test validateAllowedPattern (Params.hs)** — not directly exported, test via
`validateParams` with a `ParamDef` that has an overlength `pdAllowedPattern`:

| Case                                              | Expected                          |
|---------------------------------------------------|-----------------------------------|
| ParamDef with 1025-char AllowedPattern            | `Left "...exceeds maximum..."` |
| ParamDef with normal AllowedPattern, value matches| `Right ()`                        |

### C. HTTP timeout and max-size

These are harder to test without a real HTTP server. Test the constants and the
size-check branch:

**Test constants exist and have expected values**:
- `httpTimeoutSeconds == 30`
- `httpMaxResponseBytes == 10 * 1024 * 1024`
- `maxRegexPatternLength == 1024`

**Test loadHttpImport size rejection** — mock is hard here since `httpBS` does
real IO. Skip the timeout test (would need a slow server). Instead verify that
the constants are wired correctly by testing the `loadHttpImport` function
against a known-good URL if possible, or just test the constants.

If a local HTTP test is too complex, document it as a manual verification item.

## Implementation

### New file: `test/Test/SecurityControlsTest.hs`

```haskell
module Test.SecurityControlsTest (securityControlsTests) where

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Constants (httpTimeoutSeconds, httpMaxResponseBytes, maxRegexPatternLength)
import Iidy.Yaml.Imports.Types (ImportType(..), ImportError(..), parseImportType)
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher)
import Iidy.Yaml.CustomResources.JsonSchema (validateSchema)
-- For Params testing, use validateParams or the full pipeline

securityControlsTests :: [TestTree]
securityControlsTests =
  [ testGroup "Import trust gate" importTrustTests
  , testGroup "Regex length cap" regexLengthTests
  , testGroup "HTTP limits" httpLimitTests
  ]
```

### Wire into test/Main.hs

Add import and register in the test group list.

## Codebase Reference

| What                     | Where                                                       |
|--------------------------|-------------------------------------------------------------|
| `parseImportType`        | `src/Iidy/Yaml/Imports/Types.hs:56`                        |
| `mkFullDispatcher`       | `src/Iidy/Yaml/Imports/Loaders/Dispatch.hs:33`             |
| `validatePattern`        | `src/Iidy/Yaml/CustomResources/JsonSchema.hs:164`          |
| `validateAllowedPattern` | `src/Iidy/Yaml/CustomResources/Params.hs:109`              |
| `validateSchema`         | `src/Iidy/Yaml/CustomResources/JsonSchema.hs:28` (exported)|
| Constants                | `src/Iidy/Constants.hs`                                     |
| `loadHttpImport`         | `src/Iidy/Yaml/Imports/Loaders/Http.hs:36`                 |
| Existing import tests    | `test/Test/ImportLoaderTest.hs`                             |
| Existing schema tests    | `test/Test/JsonSchemaTest.hs`                               |
| test/Main.hs             | `test/Main.hs`                                              |

## Build/Test Commands

Per CLAUDE.md — use `~/.claude/bin/run-quiet` for builds and tests.

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet
- **Why**: Mechanical test writing. All functions are identified, test cases are
  enumerated above, and the patterns are established in existing test files.

## Progress

- [ ] Create test/Test/SecurityControlsTest.hs with import trust gate tests
- [ ] Add regex length cap tests
- [ ] Add HTTP limit constant tests
- [ ] Wire into test/Main.hs
- [ ] Build clean + all tests pass
