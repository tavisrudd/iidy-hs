# iidy Test Inventory

## Summary Statistics
- **Total Test Functions**: 192 tests (139 async + 53 sync)
- **Total Lines of Test Code**: ~9,775 LOC
- **Snapshot Files**: 98 snapshots (insta golden files)
- **Property-based Tests**: 2 proptest! blocks
- **HTTP Mock Tests**: 5 mockito-based tests
- **Benchmark Files**: 3 criterion benchmarks
- **Test Fixtures**: 6 YAML files + 98 snapshot files

## 1. Integration Tests (tests/ directory)

### A. Template Loading Integration Tests
**File**: `tests/template_loading_integration_tests.rs` (13 tests)
- `test_load_local_template_file` - Load template from local filesystem
- `test_load_template_with_render_prefix` - Template with render: prefix
- `test_http_url_template` - HTTP URL template resolution
- `test_s3_url_without_client` - S3 URL handling without client
- `test_template_size_limit_error` - Validate size limit enforcement
- `test_template_with_preprocessing_syntax_error` - Preprocessing syntax validation
- `test_inline_template_content` - Inline JSON template content
- `test_load_stack_policy_from_file` - Load stack policy from file
- `test_load_stack_policy_inline_yaml` - Inline YAML policy loading
- `test_empty_template_location` - Empty location handling
- `test_s3_url_error_handling` - Invalid S3 URL error detection
- `test_nonexistent_file_error` - Nonexistent file handling

### B. Example Templates Snapshot Tests
**File**: `tests/example_templates_snapshots.rs` (8 tests)
- `test_all_example_templates_auto_discovery` - Auto-discover and test all example templates
- `test_cloudformation_tags_structure` - CloudFormation tag preservation
- `test_invalid_templates_fail_gracefully` - Error handling for invalid templates
- `test_template_workflow_integration` - Complete workflow: config -> import -> processing
- `test_yaml_boolean_compatibility` - YAML 1.1 boolean support (yes/no/on/off)
- `test_handlebars_in_cloudformation_tags` - Handlebars in CloudFormation tags
- `test_rendering_performance` (in performance_tests cfg module) - Performance regression
- Uses insta `assert_snapshot!` for golden-file testing
- Dynamically discovers all templates in `example-templates/`
- Snapshot files: `tests/snapshots/example_templates_snapshots__*.snap` (50+ files)

### C. Error Examples Snapshot Tests
**File**: `tests/error_examples_snapshots.rs` (3 tests)
- `test_all_example_errors_auto_discovery` - Test all error templates in example-templates/errors/
- `test_error_template_helper_function` - Helper function for individual error testing
- Snapshot files: `tests/snapshots/error_examples_snapshots__*.snap` (40+ files)
- Uses NO_COLOR environment variable for consistent output

## 2. YAML Preprocessing Tests (tests/yaml/)

### A. Property-Based Tests
**File**: `tests/yaml/property.rs`
- Uses **proptest** crate
- Strategies for YAML scalars, handlebars variables, templates
- `prop_yaml_parsing_scalars` - YAML parsing consistency
- `prop_handlebars_engine_idempotent` - Handlebars idempotency
- Regression files in `proptest-regressions/`

### B. Preprocessing Integration
**File**: `tests/yaml/preprocessing_integration.rs`
- `test_complete_preprocessing_pipeline` - End-to-end preprocessing with imports, defs, conditionals, mapping, merging

### C. Equivalence Tests
**File**: `tests/yaml/equivalence.rs`
- Verifies `{{variable}}` (handlebars) = `!$ variable` (include tag)
- Tests value type preservation through different interpolation methods

### D. Error Reporting Tests
**File**: `tests/yaml/error_reporting.rs` (4+ tests)
- `test_variable_not_found_error_with_object_path`
- `test_variable_not_found_error_with_array_path`
- `test_variable_not_found_error_with_deeply_nested_path`
- `test_variable_not_found_error_with_complex_mixed_structure`

### E. Enhanced Error Reporting
**File**: `tests/yaml/enhanced_error_reporting.rs` (2+ tests)
- `test_variable_origin_access_in_context` - Variable origin tracking
- `test_import_dependency_graph_generation` - Import dependency chain tracking

### F. Preprocessing Typo Detection
**File**: `tests/yaml/preprocessing_typo_detection.rs`
- `test_unknown_iidy_tag_detection` - Catch typos like !$typo
- `test_unknown_and_or_tags_detected` - Catch !$and and !$or
- `test_other_common_typos` - 8 common typos: maps, iff, equ, nott, merges, joins, splits, lets
- 12 snapshot files in `tests/yaml/snapshots/`

### G. Additional YAML Test Modules
- `anchors_aliases.rs` - YAML anchor and alias handling
- `array_syntax.rs` - Array syntax variations
- `boolean_compatibility.rs` - YAML boolean handling
- `input_uri_traversal.rs` - Input URI handling
- `proof_of_fix.rs` - Specific bug fix validation
- `scalar_formats.rs` - Scalar value formatting
- `spec_detection.rs` - YAML specification version detection
- `variable_origin.rs` - Variable source tracking

## 3. Output Rendering Tests (tests/output/)

### A. Unit Tests (`tests/output/unit.rs`, 7+ tests)
- Metadata serialization, stack definitions, events, themes, colors, terminal width

### B. Renderer Snapshots (`tests/output/renderer_snapshots.rs`)
- Plain renderer output validation

### C. Pixel-Perfect Tests (`tests/output/pixel_perfect.rs`)
- Interactive mode output validation with fixed terminal width (130 chars)
- Validates color codes and ANSI features

### D. JSON Renderer (`tests/output/json_renderer.rs`)
### E. Fixture Validation (`tests/output/fixture_validation.rs`)
### F. Stack Events Title (`tests/output/stack_events_title.rs`)
### G. Dynamic Manager (`tests/output/dynamic_manager.rs`, 6 tests)
### H. Stack Exports Rendering (`tests/output/stack_exports_rendering.rs`, 3 tests)
### I. Output Capture Utilities (`tests/output/capture_utils.rs`)

## 4. Unit Tests in Source Code (src/)

### HTTP Import Loader (mockito-based)
**File**: `src/yaml/imports/loaders/http.rs` (8 tests)
- Uses `mockito::Server::new_async()` for HTTP mocking
- Tests: success, JSON, plain text, 404, invalid URL, connection error, large response

### YAML Parsing Property Tests
**File**: `src/yaml/parsing/proptest.rs`
- Property testing for tag generation with ConfigPresets
- CloudFormation tags: Ref, Sub, GetAtt, Join, Split, Select, Base64, ImportValue
- Preprocessing tags: $, $include, $not, $parseYaml, $parseJson, $if, $map, $merge, $let, $eq, $concat

## 5. Benchmarks (benches/)

| File | Framework | Focus |
|------|-----------|-------|
| `parsing_optimization_benchmark.rs` | criterion | serde_yaml vs tree-sitter vs custom parser |
| `simple_benchmark.rs` | custom tokio | Handlebars + preprocessing pipeline |
| `yaml_preprocessing_benchmarks.rs` | criterion | Tree-sitter vs serde_yaml |

## 6. Test Data & Fixtures

### YAML Fixtures (`tests/fixtures/`, 6 files)
1. `complex-example.yaml`
2. `create-stack-happy-path.yaml`
3. `default-features.yaml`
4. `db-config.yaml`
5. `handlebars-example.yaml`
6. `stack-args.yaml`

### Snapshot Files (`tests/snapshots/`, 98 files)
- Example template snapshots (50+)
- Error example snapshots (40+)
- Output snapshots (8)

## 7. Testing Frameworks -> Haskell Equivalents

| Rust Framework | Usage | Haskell Equivalent |
|----------------|-------|-------------------|
| insta | Snapshot/golden-file (98 snapshots) | tasty-golden, hspec-golden |
| proptest | Property-based (2 blocks) | QuickCheck, hedgehog |
| mockito | HTTP mocking (5 tests) | localstack, mock HTTP server |
| criterion | Benchmarking (3 files) | criterion (same name!) |
| tokio-test | Async test utilities | tasty-async |
| tempfile | Temporary files | temporary |

## 8. CI/CD
- `cargo fmt --check`, `cargo clippy --all-targets`, `cargo build`, `cargo test`
- Coverage: tarpaulin with 70% threshold

## 9. Key Testing Patterns

1. **Auto-Discovery**: Templates auto-discovered from `example-templates/` and dynamically tested
2. **Error Message Snapshots**: Enhanced error messages captured with formatting/context
3. **Fixture-Based**: FixtureLoader for predefined test data
4. **Equivalence**: Multiple syntax forms verified to produce identical results
5. **Integration**: Full workflow tests with temporary files
