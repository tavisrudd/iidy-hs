# Testing Strategy & Patterns

## Overview

iidy-hs tests cover the full YAML preprocessing engine, CloudFormation
operations, output rendering pipeline, CLI parsing, error handling, AWS
integration, and spec conformance. All tests run offline with no real AWS
credentials required. The suite uses the **tasty** framework and is organized
across multiple modules under `test/Test/`, with `test/Main.hs` as the entry
point.

## Framework

| Package              | Role                                      |
|----------------------|-------------------------------------------|
| tasty                | Test runner, tree-structured test groups   |
| tasty-hunit          | Assertion-based unit tests (`testCase`)   |
| tasty-quickcheck     | Property-based tests (`testProperty`)     |
| QuickCheck           | Generators and `Arbitrary` instances       |

All tests are registered in `main` via `testGroup` and run through
`defaultMain`. Tests are organized into groups by feature area across
multiple test modules in `test/Test/`.

## Test Categories

The test groups in `main` map to these feature areas:

**YAML Engine** -- Parser (core parsing, anchors, multi-document), Handlebars
(interpolation, helpers, escaping), JMESPath (expressions, filters, functions),
Emitter (output formatting, key ordering), OValue (ordered values, round-trips),
JsonSchema (Draft 7 validation), Fixtures/ErrorFixtures (end-to-end preprocessing
against expected output files).

**CloudFormation** -- StackArgsLoader (YAML loading, env parameterization),
ConvertStack (conversion helpers), RequestBuilder (capability/parameter/tag
mapping), TemplateHash (S3 URL parsing, hashing), DeleteStack (confirmation
matching), Changeset (change conversion, dashed name generation), WatchStack
(event formatting, `stackNameFromId`, mock polling via `pollForCompletionWith`),
DescribeStack (event duration calculation).

**Output Rendering** -- Renderer (interactive formatter: headings, labels, padding,
tags, timestamps, timing text), JsonRenderer (value conversion for all 26
`OutputData` types), ThemeVariants (dark/light/high-contrast/no-color themes),
RendererOutput (end-to-end through actual renderer instances), Integration
(both renderers processing all 26 variants, command-specific output sequences
for create/describe/delete/changeset/drift/lint+approval).

**CLI** -- CliParser (`optparse-applicative`: render, delete, describe,
list-stacks, global options, color flags).

**AWS** -- CredentialSource (`AwsSettings` construction), ClientReqToken
(`TokenInfo`/`DerivedTokenInfo` formatting).

**Error Handling** -- ErrorColors (TTY detection, `--color`/`NO_COLOR`, theme
selection, footer/inline colorization), error display (`formatError`, error ID
lookup, context lines).

**Properties** -- QuickCheck tests: OValue round-trips, null/bool/string
preservation, parse/emit stability, Handlebars literal passthrough, preprocessing
property tests.

**Spec Conformance** (`test/Test/SpecConformanceTest.hs`): Verifies that the
Haskell implementation agrees with the PLT Redex formal specification on key
drift-point behaviors. Reads test vectors from `spec/snapshot.json` (generated
by `spec/snapshot.rkt`). Covers:

| Section               | Tests | What's verified                               |
|-----------------------|-------|-----------------------------------------------|
| Truthiness (iidy)     | 13    | `oIsTruthy` -- 0 is falsy                     |
| Truthiness (HBS)      | 13    | `HBS.isTruthy` -- 0 is truthy                 |
| Truthiness (JMESPath) | 13    | `JMESPath.isTruthy` -- 0 is truthy             |
| Merge                 | 4     | `mergeOObjects` -- values + key-order          |
| Path resolution       | 5     | `traversePathO` -- nested, array, missing      |
| Escape                | 4     | `astToValueRaw` -- passthrough, sentinel       |
| MapValues binding     | 2     | `{key, value}` binding structure               |

The snapshot is committed to git. Regenerate with `make snapshot` after spec
changes. No Racket dependency is needed to run the Haskell tests -- only to
regenerate the snapshot.

**Snapshot Comparison** (external scripts, not part of `cabal test`):
- `scripts/snapshot-compare.sh` -- 37 render snapshots vs Rust insta `.snap` files
- `scripts/error-snapshot-compare.sh` -- 49 error snapshots vs Rust error output

Snapshots use Rust insta format (YAML header, `---`, raw output). The scripts
extract content after the second `---` line and diff against `iidy-hs render`.

## Fixture Patterns

Test fixtures live in `test-fixtures/`:

```
test-fixtures/
  example-templates/          -- Input YAML files for render tests
    errors/                   -- Input YAML files that produce errors
    yaml-iidy-syntax/         -- iidy-specific YAML syntax tests
    custom-resource-templates/ -- Custom resource expansion tests
  expected-outputs/           -- Expected output for render comparison
    yaml-iidy-syntax/
    custom-resource-templates/
  test-stack-args.yaml        -- Stack arguments loader fixture
  test-stack-args-envmap.yaml -- Environment-mapped stack args fixture
```

Fixture-based tests are built dynamically at startup. `buildFixtureTests`
discovers all `.yaml` files in `example-templates/` and pairs each with
its corresponding file in `expected-outputs/`. `buildErrorTests` does the
same for `example-templates/errors/`.

## Mock AWS Strategy

All AWS interactions are mocked. No real credentials, endpoints, or network
calls are used in the test suite. The mocking approach uses **dependency
injection via higher-order functions**:

- `pollForCompletionWith` accepts a `fetchEvents :: IO [StackEvent]` function
  instead of calling AWS directly. Tests supply an `IORef`-backed function that
  returns scripted event sequences.
- `PollConfig` provides callbacks (`pcOnNewEvents`) that tests use to capture
  intermediate state without real polling delays.
- `testPollConfig` sets `pcPollIntervalMs = 0` for instant iteration.
- Amazonka types (`CF.ResourceStatus`, `SE.StackEvent`) are constructed directly
  in test code using the `mkStackEvt` and `mkResourceEvt` helpers.

This pattern avoids the need for a mock HTTP server or AWS LocalStack. Each
test controls exactly what events are returned and in what order.

## Test Data Builders

Builder functions for all 26 `OutputData` variants live in
`test/Test/Shared.hs`. Each follows the naming convention
`test<TypeName>` -- for example, `testCommandMetadata :: CommandMetadata`,
`testStackDef :: StackDefinition`, `testStackDrift :: StackDrift`. Helper
constructors like `mkStackEvt` and `mkResourceEvt` build amazonka event types
with minimal boilerplate.

`allTestOutputData :: [OutputData]` collects all 27 entries (26 constructors;
`OdStackDefinition` appears twice with `True` and `False`). Integration tests
iterate this list to verify both renderers handle every variant without crashing.
When adding a new `OutputData` constructor, add a corresponding builder and
include it in `allTestOutputData`.

## Running Tests

All commands assume you are inside the nix devshell (`nix develop` or direnv).

```sh
# Run the full suite
cabal test

# Run with verbose output (shows individual test names)
cabal test --test-show-details=direct

# Run a specific test group by pattern (tasty pattern syntax)
cabal test --test-options='--pattern "Parser"'
cabal test --test-options='--pattern "WatchStack"'

# Run a single test by full path
cabal test --test-options='--pattern "iidy-hs/Changeset/generateDashedName format"'

# Run snapshot comparison scripts (requires both Haskell and Rust builds)
bash scripts/snapshot-compare.sh
bash scripts/error-snapshot-compare.sh
```

## Adding New Tests

1. **Where to add**: Find the relevant test module in `test/Test/` and append
   a new `testCase` or `testProperty` to the appropriate `*Tests :: [TestTree]`
   list. Shared fixtures and builders live in `test/Test/Shared.hs`.

2. **Naming convention**: Use descriptive names that state the behavior under
   test. Group name provides context, so the test name can be specific:
   `"parse boolean true"`, `"pollForCompletionWith - detects terminal status"`.

3. **Fixture files**: Place input YAML in `test-fixtures/example-templates/`
   and expected output in `test-fixtures/expected-outputs/` with the same
   relative path. The fixture discovery in `buildFixtureTests` will pick them
   up automatically.

4. **Error fixtures**: Place error-producing YAML in
   `test-fixtures/example-templates/errors/`. Expected output goes in
   `test-fixtures/expected-outputs/errors/`.

5. **New OutputData variants**: If adding a new `OutputData` constructor,
   create a `test*` builder function in `test/Test/Shared.hs`, add it to
   `allTestOutputData`, and add a case to `odConstructorName`. The integration
   tests will then automatically cover the new variant.

6. **Register in main**: If creating a new test module, add its test group
   to the `testGroup` list in `test/Main.hs`. Keep the list in logical order.

7. **Keep tests offline**: No real AWS calls. Use dependency injection
   (higher-order functions with `IORef`) for anything that would normally
   hit a network endpoint.
