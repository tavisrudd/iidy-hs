# Rust Divergences from JS Source of Truth

Items to fix in ~/src/iidy/ (the Rust port) to match ~/src/iidy-js/ behavior.

## Import System

### 1. CFN legacy dot syntax (`cfn:Stack.Key`)
- **Rust**: Supports `cfn:stackName.OutputKey` as legacy shorthand for single output lookup
- **JS**: Does not support this. Only `cfn:output:Stack/Key` format with explicit subtype field
- **Fix**: Remove dot separator from `parseCfnRef` in Rust `loaders/cfn.rs`

### 2. CFN bare shorthand (`cfn:Stack/Key`)
- **Rust**: Supports `cfn:Stack/Key` without explicit subtype, treated as output lookup
- **JS**: Does not support this. `location.split(':')` gives `["cfn", "Stack/Key"]`, field="Stack/Key" hits switch default → error
- **Fix**: Remove legacy shorthand path from Rust CFN dispatch

### 3. S3 parse failure behavior
- **Rust**: `resolve_doc_from_import_data` returns `Err` on YAML/JSON parse failure
- **JS**: `yaml.loadString` / `JSON.parse` throw on parse failure (not caught)
- **Status**: Both throw — this is actually consistent. No fix needed.

### 4. File loader parse failure behavior
- **Rust**: `resolve_doc_from_import_data` returns `Err` on YAML/JSON parse failure
- **JS**: `resolveDocFromImportData` uses same `yaml.loadString`/`JSON.parse` which throw
- **Haskell**: Falls back to String on parse failure (diverges from both)
- **Note**: Haskell File.hs fallback-to-string is tested with 37 snapshot tests passing. This may be a deliberate Haskell choice or needs investigation.
