# Snapshot Test Gap Audit

Date: 2026-03-02

## Summary

| Category                              | Count |
|---------------------------------------|------:|
| Render snapshots: PASS                |    35 |
| Render snapshots: FAIL                |     2 |
| Render snapshots: SKIP (no Rust snap) |     2 |
| Render snapshots: TOTAL               |    39 |
| Error snapshots: PASS                 |    48 |
| Error snapshots: FAIL                 |     1 |
| Error snapshots: SKIP (no Rust snap)  |     2 |
| Error snapshots: TOTAL                |    51 |
| `cabal test` total                    |  1081 |
| Fixture tests in cabal (render)       |    35 |
| Error fixture tests in cabal          |    51 |
| Error content tests in cabal          |    51 |
| Missing Rust yaml-iidy-syntax fixtures|     4 |

## Snapshot Failures

### Render Failures (2)

**1. `advanced-cloudformation.yaml`** -- render error (exit 1)

Haskell CFN validator rejects `!Select [0, !GetAZs ""]` because it sees `!GetAZs ""` as an
"object" (tagged value) rather than recognizing it as a CFN intrinsic that will produce an
array at deploy time. Rust passes through CFN intrinsics without deep type checking on nested
intrinsic return types.

Error message:
```
CloudFormation error: !Select expects [index, array], found [number, object]
@ test-fixtures/example-templates/advanced-cloudformation.yaml:67:33 (errno: ERR_7001)
```

Root cause: `!Select` validation in the CFN validator validates the second element's *AST type*
(which is an object/mapping because `!GetAZs` is represented as a tagged scalar that becomes a
single-key mapping). Rust does not validate nested intrinsic return types. This is a validation
strictness difference.

**2. `string-formatting-demo.yaml`** -- render error (exit 1)

Same root cause. This fixture also contains `!Select [0, !GetAZs '']` (at line 165). The CFN
validator rejects it identically.

Error message:
```
CloudFormation error: !Select expects [index, array], found [number, object]
@ test-fixtures/example-templates/string-formatting-demo.yaml:165:1 (errno: ERR_7001)
```

### Error Snapshot Failures (1)

**1. `cloudformation-empty-arrays`** -- word difference

```diff
< ... found array @ ...
> ... found sequence @ ...
```

Haskell says "sequence" where Rust says "array". The error message text differs by one word.
The error code (ERR_7001), position, and structure all match. This is a cosmetic divergence in
the type name used for YAML sequences in error messages.

## Snapshot Skips

### Render Skips (2)

| Fixture                | Reason                                                      |
|------------------------|-------------------------------------------------------------|
| `handlebars-in-tags`   | Rust snapshot uses `assert_yaml_snapshot!` (serde_yaml       |
|                        | serialization) not CLI output. Different quoting conventions.|
|                        | Tested via cabal test Fixtures group with expected-output.   |
| `yaml-11-booleans`     | Same: Rust uses `assert_yaml_snapshot!` not CLI output.      |
|                        | Tested via cabal test Fixtures group with expected-output.   |

These two fixtures are covered by `cabal test` (FixtureTest), so the SKIP is acceptable.
The snapshot-compare script comment documents this intentional exclusion.

### Error Skips (2)

| Fixture                | Reason                                          |
|------------------------|-------------------------------------------------|
| `expand-missing-template` | No Rust snapshot exists for this fixture.     |
| `expand-parse-error`      | No Rust snapshot exists for this fixture.     |

Both are Haskell-only error fixtures (added for coverage). They ARE tested in cabal
(ErrorFixtureTest confirms they error; ErrorContentTest checks error codes and phrases).

## Missing Rust Fixtures

Rust has 4 yaml-iidy-syntax snapshot fixtures that Haskell does not have:

| Rust snapshot name                | Status                                     |
|-----------------------------------|--------------------------------------------|
| `defs_dynamic_scoping`            | No Haskell fixture file exists             |
| `defs_handlebars_cross_reference` | No Haskell fixture file exists             |
| `defs_mixed_references`           | No Haskell fixture file exists             |
| `include_equivalence2`            | No Haskell fixture file exists             |

These represent Rust test coverage for `$defs` features that may exercise paths not
covered by the existing Haskell fixtures for `$defs`.

## Gap Analysis

### Snapshot-only coverage (tested by snapshot scripts, NOT by `cabal test`)

These 4 fixtures pass in `scripts/snapshot-compare.sh` but have no expected-output file
for the cabal Fixtures test group:

| Fixture                    | Snapshot result | cabal test coverage |
|----------------------------|-----------------|---------------------|
| `config`                   | PASS            | None (no expected-output) |
| `import-test`              | PASS            | None (no expected-output) |
| `advanced-cloudformation`  | FAIL            | None (no expected-output) |
| `string-formatting-demo`   | FAIL            | None (no expected-output) |

Of these, `config` and `import-test` pass in snapshot comparison but have zero cabal test
coverage for their rendered output. If the snapshot-compare script stops being run, regressions
in these two fixtures would go undetected.

### cabal-test-only coverage (tested by `cabal test`, no snapshot comparison)

The following test modules test code paths with no corresponding snapshot comparison:

| Test module              | Tests | What it covers                              |
|--------------------------|------:|---------------------------------------------|
| HelpTest                 |     5 | CLI help formatting                         |
| ParserTest               |    30 | YAML parser (scalars, spans, tags)          |
| JMESPathTest             |    17 | JMESPath evaluation                         |
| HandlebarsTest           |    13 | Handlebars template engine                  |
| EmitterTest              |    16 | YAML emitter (scalars, tags, multiline)     |
| StackArgsLoaderTest      |    14 | Stack args loading + env map resolution     |
| ConvertStackTest         |    11 | convert-stack operation                     |
| TemplateHashTest         |     6 | Template hashing + S3 URLs                  |
| CliParserTest            |    18 | CLI argument parsing + format validation    |
| OValueTest               |    22 | OValue truthiness, conversion, emitter      |
| RequestBuilderTest       |    23 | CFN request building (params, tags, caps)   |
| JsonSchemaTest           |    16 | JSON Schema Draft 7 validator               |
| DeleteStackTest          |    10 | Confirmation input parsing                  |
| ChangesetTest            |    19 | Changeset conversion + error handling       |
| PropertyTest             |    36 | QuickCheck properties (parser, emitter, etc)|
| WatchStackTest           |    24 | Stack polling, terminal status detection    |
| ErrorColorTest           |     7 | ANSI color in error output                  |
| RendererTest             |    34 | Interactive renderer formatting             |
| JsonRendererTest         |    35 | JSON renderer value conversion              |
| ThemeVariantTest         |    14 | Theme color variants                        |
| RendererOutputTest       |    14 | Renderer output formatting                  |
| IntegrationTest          |    17 | End-to-end output dispatch sequences        |
| Phase14FixTest           |    21 | Phase 14 bug fixes                          |
| FilehashTest             |    11 | File hashing imports                        |
| ImportLoaderTest         |    17 | Import loader routing (env, git, random, http) |
| AwsLoaderTest            |    37 | AWS loader parsing (S3, SSM, CFN)           |
| ErrorIdTest              |     6 | Error code round-trip + uniqueness          |
| ErrorClassificationTest  |    31 | Error classification + message building     |
| ResolverTest             |   106 | All preprocessing tags (map, merge, let, etc) |
| CfnYamlEmitterTest       |    44 | CFN YAML emission (numbers, quoting, nesting) |
| ChangesetHelpersTest     |    25 | Changeset URL building, percent encoding    |
| DescribeStackTest        |    18 | Event duration calc, console URL, converters |
| StackOpsConverterTest    |    11 | Resource/output/changeset conversion        |
| TimingTest               |    19 | NTP packet parsing, time providers          |
| SecurityControlsTest     |    14 | Import trust gate, regex caps, HTTP limits  |
| ParamsClientTest         |     8 | SSM parameter formatting                    |
| TemplateLoaderTest       |    12 | Template loading (URL, render, local)       |
| GlobalConfigTest         |    14 | SSM global config application               |
| PreprocessingPropertyTest|    20 | Preprocessing tag semantic QuickCheck laws  |
| ErrorContentTest         |    51 | Error message content verification          |

These modules provide ~830+ tests covering internal logic that has no external snapshot
equivalent. This is expected -- snapshots only test the render pipeline end-to-end.

### Render/error paths with NEITHER snapshot NOR cabal test coverage

**Source modules with no dedicated test module and no fixture coverage:**

| Module                                   | Coverage status                           |
|------------------------------------------|-------------------------------------------|
| `Iidy.Demo`                              | No tests. Demo command output untested.   |
| `Iidy.Explain`                           | No tests. Explain command output untested. |
| `Iidy.GetImport`                         | No tests. get-import command logic untested (CLI parser tested). |
| `Iidy.Confirm`                           | No dedicated tests. Used by delete-stack (tested indirectly). |
| `Iidy.Output.Spinner`                    | No tests. Spinner animation untested (hard to unit test). |
| `Iidy.Output.Terminal`                   | No tests. Terminal width detection untested. |
| `Iidy.Output.Manager`                    | No tests. Output dispatch manager untested (integration tests exercise it). |
| `Iidy.Cfn.Operations.CreateStack`        | No unit tests. Requires live AWS (mock integration tests exist). |
| `Iidy.Cfn.Operations.UpdateStack`        | No unit tests. Requires live AWS.         |
| `Iidy.Cfn.Operations.DeleteStack`        | DeleteStackTest tests helpers only, not operation itself. |
| `Iidy.Cfn.Operations.CreateOrUpdate`     | No unit tests. Requires live AWS.         |
| `Iidy.Cfn.Operations.Changeset`          | ChangesetTest tests converters, not operation. |
| `Iidy.Cfn.Operations.DescribeStack`      | DescribeStackTest tests converters, not operation. |
| `Iidy.Cfn.Operations.DescribeStackDrift` | No unit tests. Requires live AWS.         |
| `Iidy.Cfn.Operations.WatchStack`         | WatchStackTest tests polling logic, not full operation. |
| `Iidy.Cfn.Operations.ListStacks`         | No unit tests. Requires live AWS.         |
| `Iidy.Cfn.Operations.LintTemplate`       | No unit tests. Requires live AWS.         |
| `Iidy.Cfn.Operations.EstimateCost`       | No unit tests. Requires live AWS.         |
| `Iidy.Cfn.Operations.TemplateApproval`   | No unit tests. Requires live AWS.         |
| `Iidy.Cfn.Operations.GetStackTemplate`   | No unit tests. Requires live AWS.         |
| `Iidy.Yaml.Imports.Loaders.Http`         | URL parsing tested; actual HTTP untested. |
| `Iidy.Yaml.Imports.Loaders.S3`           | URI parsing tested; actual S3 untested.   |
| `Iidy.Yaml.Imports.Loaders.Cfn`          | Location parsing tested; actual CFN untested. |
| `Iidy.Yaml.PathTracker`                  | No tests (internal utility).              |
| `Iidy.Yaml.CustomResources.RefRewriting` | No dedicated tests (exercised by fixture tests). |
| `Iidy.Yaml.CustomResources.Expansion`    | No dedicated tests (exercised by fixture tests). |
| `Iidy.Yaml.CustomResources.Params`       | No dedicated tests (exercised by fixture tests). |

Notes:
- CFN operation modules (CreateStack, UpdateStack, etc.) require live AWS and are tested
  through Phase 14 live verification, not automated tests. The pure helper functions they
  call (converters, builders, formatters) ARE tested.
- Custom resource modules are exercised indirectly through the 5 custom-resource fixture
  tests (data-lake, event-processors, multi-role-stack, overrides-demo, queue-consumers).
- Spinner and Terminal modules are inherently difficult to unit test (they interact with
  the terminal).

## Recommendations

### High priority

1. **Fix `!Select` CFN validation to accept nested CFN intrinsics.** Both render snapshot
   failures (`advanced-cloudformation`, `string-formatting-demo`) have the same root cause:
   the validator rejects `!Select [index, !GetAZs ""]` because it sees `!GetAZs` as an
   object instead of recognizing it as an array-producing intrinsic. Rust passes these
   through. This is a correctness bug.

2. **Fix "sequence" -> "array" wording in cloudformation-empty-arrays error.** The one error
   snapshot failure is a single-word divergence. Rust says "array", Haskell says "sequence".
   Should match Rust for consistency.

3. **Add expected-output files for `config` and `import-test`.** These two fixtures pass
   snapshot comparison but have no cabal test coverage. Adding expected-output files would
   bring them into the automated test suite.

### Medium priority

4. **Port 4 missing yaml-iidy-syntax fixtures from Rust:** `defs-dynamic-scoping`,
   `defs-handlebars-cross-reference`, `defs-mixed-references`, `include-equivalence2`.
   These test `$defs` features that may not be fully exercised by existing fixtures.

5. **Add tests for `Demo` and `Explain` commands.** These produce user-visible output with
   no test coverage. At minimum, smoke tests that they don't crash and produce non-empty output.

6. **Add tests for `GetImport` command.** The command logic for dispatching imports and
   formatting output has no direct test.

### Low priority

7. **Custom resource modules** (`RefRewriting`, `Expansion`, `Params`) are covered indirectly
   by fixture tests. Dedicated unit tests would make failures easier to diagnose but are not
   critical.

8. **CFN operation modules** are inherently live-AWS-dependent. The current approach (test
   pure helpers, verify operations manually) is reasonable. Mock-based operation tests could
   be added but have limited value vs. live testing.

9. **PathTracker, Spinner, Terminal** are infrastructure modules that are hard to unit test
   and low risk. No action needed.
