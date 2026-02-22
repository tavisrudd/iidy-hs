# Phase 7: Error Display System

**Status**: DONE (Sessions 13-17)
**Depends on**: Phase 2 (YAML engine), Phase 6 (test infra)
**Gate**: 49/49 error snapshots match Rust output

## Problem Statement

Enhanced error display is not wired up. Errors print as raw `Show` instances instead of the formatted output Rust produces. This is the biggest remaining gap: 0/49 error snapshots match.

## Research (Session 13)

### Rust Error Architecture

The Rust error system has 4 layers:

1. **Error IDs** (`~/src/iidy/src/yaml/errors/ids.rs`, 402 LOC)
   - `ErrorId` enum with 50 variants across 9 categories (1xxx–9xxx)
   - Methods: `code()` → `"ERR_2001"`, `category()`, `description()`, `detailed_explanation()`
   - Only 4 have embedded docs: ERR_1001, ERR_2001, ERR_4002, ERR_5001

2. **Enhanced Errors** (`~/src/iidy/src/yaml/errors/enhanced.rs`, 759 LOC)
   - `EnhancedPreprocessingError` enum with 6 variants:
     - `VariableNotFound` { variable, available_vars, suggestions (fuzzy) }
     - `TypeMismatch` { expected, found, context, help }
     - `CloudFormationValidation` { tag_name, message, help }
     - `YamlSyntax` { short_message, guidance, fix_hint, example }
     - `TagParsing` { tag_name, message, suggestion, caret_column, span_len }
     - `LookupQuery` { variable_path, message, available_keys }
   - `display_with_context()` is main render method (lines 124-262)
   - `fuzzy_match_variables()` uses Levenshtein distance (lines 630-647)

3. **Display helpers** (`~/src/iidy/src/yaml/errors/display.rs`, 508 LOC)
   - `ErrorColors`: bold_red, red, cyan, blue_grey, light_blue, grey, reset
   - `format_source_context()` (lines 88-160): renders 3 source lines + carets
   - `find_tag_column()` (lines 166-212): locates tag in source line
   - `tag_example()` (lines 401-457): generates per-tag usage examples

4. **Wrapper/Factory** (`~/src/iidy/src/yaml/errors/wrapper.rs`, 344 LOC)
   - `FormattedError` wraps `EnhancedPreprocessingError` + `source_lines`
   - Factory functions called from resolver:
     - `variable_not_found_error()` (lines 35-70)
     - `tag_parsing_error()` (lines 155-198)
     - `type_mismatch_error_with_path_tracker()` (lines 212-227)
     - `cloudformation_validation_error_with_path_tracker()` (lines 267-275)
     - `lookup_query_error()` (lines 319-344)
   - Key: errors carry structured data, formatting happens at display time

### Haskell Current State

**What's READY (already implemented):**
- `src/Iidy/Yaml/Errors/Display.hs` — `formatError` handles all 6 variants
  - `formatHeader`, `formatGuidance`, `formatSourceContext`, `formatSuggestions`, `formatDidYouMean`, `formatHelp`, `formatExample`, `formatFooter`
- `src/Iidy/Yaml/Errors/Enhanced.hs` — all 6 info types with correct fields
- `src/Iidy/Yaml/Errors/Ids.hs` — 72 ErrorId codes with `showErrorId`
- `src/Iidy/Explain.hs` — full error database (72 entries)
- `src/Iidy/Yaml/Errors/Display.hs:19-41` — ErrorColors with ANSI codes

**What's BROKEN (the gap):**

1. **Resolver uses plain `ResolveError`** (Resolver.hs:30-33):
   ```haskell
   data ResolveError = ResolveError
     { rePosition :: !Position
     , reMessage  :: !Text
     } deriving stock (Show, Eq)
   ```
   - All 30+ `resolveError` calls pass raw text messages, no ErrorId

2. **Engine wraps in `PreprocessError`** (Engine.hs:36-41):
   ```haskell
   data PreprocessError
     = PeResolveError !ResolveError  -- just wraps the raw error
     | PeImportError !ImportError
     | PeHandlebarsError !InterpolateError
     | PeCycleError !Text
   ```

3. **Render.hs uses `show`** (Render.hs:91-96):
   ```haskell
   formatPreprocessError :: PreprocessError -> Text
   formatPreprocessError = \case
     PeResolveError re -> "Resolve error: " <> T.pack (show re)
     ...
   ```
   Produces: `"Resolve error: ResolveError {rePosition = ..., reMessage = ...}"`

4. **Error output in Render.hs:59**:
   ```haskell
   Left err -> do
     TIO.hPutStrLn stderr $ "Preprocess error: " <> formatPreprocessError err
     exitWith (ExitFailure 1)
   ```

### Exact Rust Output Format (from snapshots)

```
{Category} error: {message} @ {file}:{line}:{col} (errno: {ERROR_CODE})
  -> {hint text}

   N | context line before
   N | error line here
     | ^^^^ pointer text

   {guidance/suggestion text}

   For more info: iidy explain {ERROR_CODE}
```

Categories seen: "Tag error", "Type error", "CloudFormation error", "Syntax error", "Variable error", "Lookup error"

### Snapshot Examples

**Tag error (ERR_4002):**
```
Tag error: 'template' missing in !$map tag @ example-templates/errors/map-missing-template.yaml:2:11 (errno: ERR_4002)
  -> add 'template' field to !$map tag

   1 | # !$map with missing template field error
   2 | test_map: !$map
   3 |   items: ["a", "b", "c"]

   example:
   !$map
     items: [1, 2, 3]
     template: "{{item}}"
   For more info: iidy explain ERR_4002
```

**Type error (ERR_5001):**
```
Type error: expected string, found object @ example-templates/errors/join-wrong-array-item-type.yaml:2:18 (errno: ERR_5001)
  -> data type mismatch

   1 | # !$join with array containing non-string-convertible items
   2 | test_join: !$join [",", ["hello", {key: value}, "world"]]
     |                  ^^^^^^^^ expected string

   expected string, found object
   try using !$toJsonString or !$toYamlString to serialize the object

   For more info: iidy explain ERR_5001
```

**Variable error (ERR_2001):**
```
Variable error: 'app_name' not found @ example-templates/errors/variable-not-found.yaml:6:15 (errno: ERR_2001)
  -> variable not defined in current scope

   5 |
   6 | stack_name: "{{app_name}}-{{environment}}"
     |               ^^^^^^^^^^^ variable not defined

   available variables: environment, region

   For more info: iidy explain ERR_2001
```

**CloudFormation error (ERR_7001):**
```
CloudFormation error: !Join expects a 2-element array, found string @ example-templates/errors/cloudformation-wrong-element-count.yaml:17:25 (errno: ERR_7001)
  -> invalid CloudFormation intrinsic function

  16 |       # Invalid !Join - only has one element instead of [delimiter, array]
  17 |       BucketName: !Join ["-"]
     |                         ^^^^ invalid CloudFormation tag
  18 |

   !Join expects [delimiter, array] with exactly 2 elements
   example: Name: !Join ['-', [!Ref 'AWS::StackName', 'suffix']]

   For more info: iidy explain ERR_7001
```

## Implementation Plan

### 7.1: Convert PreprocessError → EnhancedPreprocessingError

**Approach**: Add a conversion function in Engine.hs or a new module that:
1. Pattern-matches on `reMessage` text to classify the error
2. Extracts error category, ErrorId, guidance from the message
3. Constructs the appropriate `EnhancedPreprocessingError` variant
4. Reads source file for context (file path from resolver position)

**Key mapping from message patterns to error types:**
- `"'...' missing in !$..."` → TagParsingError, ERR_4002
- `"must be a ..."` → TagParsingError, ERR_4003
- `"expected .*, found .*"` → TypeMismatchError, ERR_5001
- `"Variable not found: ..."` → VariableNotFoundError, ERR_2001
- `"JMESPath error: ..."` → LookupQueryError, ERR_2006
- `"!Ref ..." / "!Join ..."` → CfnValidationError, ERR_7001
- `"invalid format..."` → TagParsingError, ERR_4005
- `"is not a valid iidy tag"` → TagParsingError, ERR_4001

**Wire up in Render.hs:**
- Replace `formatPreprocessError` call with conversion + `formatError`
- Pass source file content (read from disk using file path in error position)

### 7.2: Fix error format to match Rust exactly

After 7.1, compare each snapshot and adjust:
- Header format: `{Cat} error: {msg} @ {file}:{line}:{col} (errno: {CODE})`
- Guidance text per error type
- Source context line formatting (line numbers, padding, carets)
- Example blocks per tag type
- Footer format

### 7.3: Fix 11 UNEXPECTED_OK validation gaps

Add validation checks in resolver for:
- [x] Unknown !$ tags (typo detection)
- [x] Unknown fields in tag mappings
- [x] CFN intrinsic validation (!Ref, !Join, !GetAtt args)
- [x] Mutual exclusivity (query vs jmespath)
- [x] Non-string items in !$join
- [x] Missing keys in query results
- [x] Handlebars variable not in scope

### 7.4: Final verification — 49/49 PASS

## Gate Criteria
```bash
cabal build 2>&1 | grep -c warning  # must be 0
cabal test                            # all tests pass
scripts/error-snapshot-compare.sh     # 49/49 PASS
scripts/snapshot-compare.sh           # 36/36 PASS (no regressions)
```
