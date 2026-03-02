# Implement render: Template Preprocessing -- Feature Fix

**Date**: 2026-03-01
**Session**: `9b77427d-2cd4-4c4b-a7a0-d2726e72261d`
**References**: Codex review, Rust `src/cfn/template_loader.rs:29-161`

## Context

The `render:` prefix on `Template:` in stack-args.yaml is supposed to run
the full YAML preprocessing pipeline on the CFN template before sending it
to CloudFormation. This is critical for templates that use `$imports`,
`$defs`, handlebars interpolation, or custom tags.

The Haskell code detects the prefix and loads the file, but **never calls
the preprocessor**. The comment on line 53 of `TemplateLoader.hs` says
`"(future: integrate with YAML engine)"`. This makes `render:` a no-op —
the raw unprocessed file is sent to CloudFormation, which will reject
templates containing `$imports:` or other iidy syntax.

**Impact**: Affects ALL operations that load templates: create-stack,
update-stack, create-changeset, create-or-update, lint-template,
estimate-cost, template-approval.

## Key Architecture Decision

The preprocessing engine already works and is used in two places:
- `Render.hs:64` — standalone `render` command
- `StackArgsLoader.hs:76` — argsfile loading

Both use `preprocessYaml11` from `Iidy.Yaml.Engine` with
`mkFullDispatcher` from `Iidy.Yaml.Imports.Loaders.Dispatch`.

The `render:` template path should follow the same pattern, with the
additional step of injecting `$envValues` into the parsed AST before
preprocessing (matching Rust `template_loader.rs:117-131`).

## Chunks

### 1. Wire preprocessing into TemplateLoader.hs render: path

Current code (lines 53-57):
```haskell
  | Just renderPath <- T.stripPrefix "render:" tmplSpec = do
      let resolvedPath = resolveTemplatePath (T.unpack renderPath) argsfilePath
      body <- loadFileContent resolvedPath
      pure (TemplateResult (Just body) Nothing)
```

Replace with:
```haskell
  | Just renderPath <- T.stripPrefix "render:" tmplSpec = do
      let resolvedPath = resolveTemplatePath (T.unpack renderPath) argsfilePath
          baseLocation = T.pack resolvedPath
      rawContent <- BL.readFile resolvedPath
      case parseYaml rawContent baseLocation of
        Left (ParseError _pos msg) ->
          fail $ "Parse error in rendered template " <> T.unpack baseLocation <> ": " <> T.unpack msg
        Right ast -> do
          -- Inject $envValues before preprocessing (matches Rust)
          let astWithEnv = injectEnvValuesIntoAst ast env
          result <- preprocessYaml11 (mkFullDispatcher mAwsEnv) astWithEnv baseLocation
          case result of
            Left err ->
              fail $ "Preprocess error in rendered template " <> T.unpack baseLocation <> ": " <> show err
            Right (PreprocessResult val _manifest) -> do
              let rendered = emitYaml val  -- or serializeOValue / toYamlText
              checkTemplateSize rendered
              pure (TemplateResult (Just rendered) Nothing)
```

**Signature change needed**: `loadCfnTemplate` currently ignores its `_env`
parameter and has no access to an AWS env for the dispatcher. The signature
needs to become:

```haskell
loadCfnTemplate :: Maybe Text -> Maybe FilePath -> Text -> Maybe Amazonka.Env -> IO TemplateResult
```

This adds `Maybe Amazonka.Env` for the import dispatcher (`mkFullDispatcher`).
The `Text` parameter (currently `_env`) is the environment name for `$envValues`.

All callers (in `RequestBuilder.hs` lines 62, 94, 132; `LintTemplate.hs`;
`EstimateCost.hs`; `TemplateApproval.hs`) need updating.

**New imports for TemplateLoader.hs:**
- `Iidy.Yaml.Engine (preprocessYaml11, parseYaml, PreprocessResult(..), ParseError(..))`
- `Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher)`
- `Iidy.Yaml.OValue` (for serialization)
- `qualified Data.ByteString.Lazy as BL`
- `qualified Amazonka`

**`injectEnvValuesIntoAst`**: New helper that inserts a `$envValues` mapping
(with `environment` key) into the top-level YAML mapping before preprocessing.
Rust does this at `template_loader.rs:117-131`. Only injects `environment`;
Rust's `region` TODO is also unimplemented there.

### 2. Add $imports: detection guard

Rust (`template_loader.rs:88-103`) errors when a template contains `$imports:`
but lacks the `render:` prefix, giving a helpful message. Add to the
`otherwise` (local file) branch:

```haskell
  | otherwise = do
      -- ... load file ...
      when (hasImportsKey body && not (T.isPrefixOf "render:" tmplSpec)) $
        fail $ "Template contains $imports: but was not loaded with render: prefix. "
            <> "Use Template: render:" <> T.unpack tmplSpec
```

### 3. Add size check to render: path

The current `render:` path skips `checkTemplateSize`. Add it after
preprocessing (the rendered output may be larger than the raw input).

### 4. Integration tests

Zero tests exist for `loadCfnTemplate`. Rust has 8 integration tests in
`tests/template_loading_integration_tests.rs`. Add tests for:

- Local file (plain load, size check)
- `render:` prefix with `$imports:` (verify preprocessing runs)
- `render:` prefix with `$envValues` (verify injection)
- `$imports:` without `render:` prefix (verify error)
- Size limit on rendered output
- Request, lint, and approval flows (end-to-end with `render:`)

## Codebase Reference

| What                        | Where                                                     |
|-----------------------------|-----------------------------------------------------------|
| `loadCfnTemplate`           | `src/Iidy/Cfn/TemplateLoader.hs` (lines 46-69)           |
| `preprocessYaml11`          | `src/Iidy/Yaml/Engine.hs` (line 53)                      |
| `mkFullDispatcher`          | `src/Iidy/Yaml/Imports/Loaders/Dispatch.hs` (line 31)    |
| `parseYaml`                 | `src/Iidy/Yaml/Engine.hs`                                |
| `injectEnvValues` (argsfile)| `src/Iidy/Cfn/StackArgsLoader.hs` (lines 152-165)        |
| `buildEnvValues`            | `src/Iidy/Cfn/StackArgsLoader.hs` (lines 168-183)        |
| Callers: RequestBuilder     | `src/Iidy/Cfn/RequestBuilder.hs` (lines 62, 94, 132)     |
| Callers: LintTemplate       | `src/Iidy/Cfn/Operations/LintTemplate.hs` (line 39)      |
| Callers: EstimateCost       | `src/Iidy/Cfn/Operations/EstimateCost.hs` (line 39)      |
| Callers: TemplateApproval   | `src/Iidy/Cfn/Operations/TemplateApproval.hs` (line 58)  |
| Rust reference              | `~/src/iidy/src/cfn/template_loader.rs` (lines 29-161)   |
| Rust tests                  | `~/src/iidy/tests/template_loading_integration_tests.rs`  |
| Render.hs (working example) | `src/Iidy/Render.hs` (line 64)                           |
| YAML emitter                | `src/Iidy/Yaml/Emitter.hs`                               |

## Build/Test Commands

Per CLAUDE.md.

## Delegation Strategy

- **Chunk 1** (preprocessing wiring): **Opus** — touches TemplateLoader signature,
  all callers, and architectural wiring across modules.
- **Chunk 2** ($imports guard): **Sonnet** — small, isolated check in one branch.
- **Chunk 3** (size check): **Sonnet** — one-line addition.
- **Chunk 4** (tests): **Sonnet** — mechanical test writing once the implementation
  is done and the patterns are established.

## Workflow Instructions

- Read this file first
- Chunk 1 is the critical path — start there
- After Chunk 1, verify with a manual test: create a template with `$imports:`
  and use `render:` prefix — confirm it preprocesses correctly
- Chunks 2-3 are small and can be done in the same session
- Chunk 4 should be a separate session or sub-agent

## Progress

- [ ] Chunk 1: Wire preprocessYaml11 into render: path + update signature + update callers
- [ ] Chunk 2: Add $imports: detection guard
- [ ] Chunk 3: Add size check to render: path
- [ ] Chunk 4: Integration tests for TemplateLoader
- [ ] Final: build clean + all tests pass

## Handoff Notes

(none yet)
