# TemplateLoader render: Integration Tests -- Test Enhancement

**Date**: 2026-03-01
**Session**: `00cdf3e0-e600-42b8-8b73-07f9dcd707ad`

## Context

`Iidy.Cfn.TemplateLoader` is the entry point for loading CloudFormation templates. The
`render:` prefix triggers full YAML preprocessing (imports, $defs, handlebars, JMESPath).
While fixture tests cover the preprocessing pipeline end-to-end, there are no direct
integration tests for `loadCfnTemplate` itself — testing the render: path, error handling,
size limits, and S3/HTTP URL passthrough.

## What TemplateLoader Does

`loadCfnTemplate :: Maybe Text -> Maybe FilePath -> Text -> Maybe Amazonka.Env -> IO TemplateResult`

| Input pattern       | Behavior                                              |
|---------------------|-------------------------------------------------------|
| `render:<path>`     | Parse → inject $envValues → preprocess → emit YAML   |
| `s3://...`          | Return as TemplateUrl (CFN fetches directly)          |
| `http(s)://...`     | Return as TemplateUrl                                 |
| Local file path     | Read file, check for $imports, check size, return     |
| Inline YAML         | Treat as literal content                              |
| `Nothing`           | Return empty result                                   |

## Test Chunks

### Chunk 1: Success Paths (no AWS)

Test `loadCfnTemplate` with `Nothing` for AWS env, using local fixtures:

```haskell
-- render: with simple template (no imports)
test_render_simple = do
  result <- loadCfnTemplate (Just "dev") (Just "test-fixtures/") "render:example.yaml" Nothing
  assertJust (trTemplateBody result)
  -- body should contain rendered YAML

-- render: with $defs
test_render_with_defs = do
  -- fixture with $defs section
  result <- loadCfnTemplate (Just "staging") (Just "test-fixtures/") "render:defs-template.yaml" Nothing
  -- $defs should be resolved, $envValues.environment = "staging"

-- S3 URL passthrough
test_s3_url = do
  result <- loadCfnTemplate Nothing Nothing "s3://my-bucket/template.yaml" Nothing
  assertEqual (trTemplateUrl result) (Just "s3://my-bucket/template.yaml")
  assertNothing (trTemplateBody result)

-- HTTP URL passthrough
test_http_url = do
  result <- loadCfnTemplate Nothing Nothing "https://example.com/t.yaml" Nothing
  assertEqual (trTemplateUrl result) (Just "https://example.com/t.yaml")

-- Local file (no render:)
test_local_file = do
  result <- loadCfnTemplate Nothing (Just "test-fixtures/") "simple.yaml" Nothing
  assertJust (trTemplateBody result)

-- Nothing input
test_nothing = do
  result <- loadCfnTemplate Nothing Nothing "" Nothing
  -- depends on behavior for empty string
```

### Chunk 2: Failure Paths

```haskell
-- render: with parse error (malformed YAML)
test_render_parse_error = do
  -- create temp file with malformed YAML
  result <- loadCfnTemplate Nothing (Just dir) "render:malformed.yaml" Nothing
  -- should contain "Parse error in rendered template"

-- render: with preprocess error (undefined variable)
test_render_preprocess_error = do
  -- template referencing {{undefined_var}}
  result <- loadCfnTemplate Nothing (Just dir) "render:bad-var.yaml" Nothing
  -- should contain "Preprocess error"

-- Local file with $imports: but no render: prefix
test_imports_without_render = do
  -- file containing "$imports:" directive
  result <- loadCfnTemplate Nothing (Just dir) "has-imports.yaml" Nothing
  -- should error: "You need to prefix the template location with render:"

-- Size limit exceeded
test_size_limit = do
  -- create temp file > 51199 bytes
  result <- loadCfnTemplate Nothing (Just dir) "render:huge.yaml" Nothing
  -- should error about size limit
```

### Chunk 3: AWS Import Contexts (mock-based)

Test render: flow with AWS imports using mock AWS env (if feasible with existing
mock infrastructure from AwsLoaderTest.hs):

```haskell
-- render: template with ssm: import (mock SSM response)
test_render_with_ssm_import = ...

-- render: template with cfn:output import (mock CFN response)
test_render_with_cfn_import = ...

-- render: with AWS import but no AWS env → graceful error
test_render_aws_import_no_env = do
  result <- loadCfnTemplate (Just "dev") (Just dir) "render:uses-ssm.yaml" Nothing
  -- should fail with "AWS import type requires credentials"
```

## Codebase Reference

| What                     | Where                                          |
|--------------------------|-------------------------------------------------|
| TemplateLoader           | `src/Iidy/Cfn/TemplateLoader.hs` (180 LOC)    |
| TemplateResult type      | `src/Iidy/Cfn/TemplateLoader.hs:25-27`         |
| loadCfnTemplate          | `src/Iidy/Cfn/TemplateLoader.hs:62`            |
| Render command           | `src/Iidy/Render.hs` (120 LOC)                 |
| Existing fixture tests   | `test/Test/FixtureTest.hs` (44 fixtures)       |
| AWS loader mocks         | `test/Test/AwsLoaderTest.hs`                   |
| RequestBuilder (caller)  | `src/Iidy/Cfn/RequestBuilder.hs`               |
| Engine (preprocessing)   | `src/Iidy/Yaml/Engine.hs` (~300 LOC)           |
| Test fixtures dir        | `test-fixtures/example-templates/`             |

## Delegation Strategy

### Chunk 1 (Success paths)
- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — straightforward test writing with clear specs
- **Note**: May need to create small test fixture YAML files

### Chunk 2 (Failure paths)
- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — needs to create temp files for error conditions
- **Note**: Use `System.IO.Temp` for temp directories

### Chunk 3 (AWS mocks)
- **Can delegate?** Maybe
- **Sub-agent type**: Opus — needs to understand mock AWS infrastructure
- **Note**: Check if AwsLoaderTest.hs has reusable mock patterns; may be complex

Chunks 1 and 2 can run in parallel. Chunk 3 depends on understanding mock patterns.

## Progress

- [ ] Chunk 1: Success path tests (render:, S3, HTTP, local, nothing)
- [ ] Chunk 2: Failure path tests (parse error, preprocess error, size limit, imports-without-render)
- [ ] Chunk 3: AWS import mock tests (if feasible)
- [ ] Create test fixtures as needed
- [ ] Wire into test/Main.hs, update cabal
- [ ] All tests pass, zero warnings

## Handoff Notes

(to be filled by implementing session)
