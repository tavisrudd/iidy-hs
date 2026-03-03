# Code Review Round 1: Render Command Orchestration

**Date**: 2026-03-01
**Round**: 1 of 3
**Scope**: 
- src/Iidy/Render.hs
**Prior reviews**: none (initial review)

## Grade: 90/100

## Summary
The `runRender` module provides the high-level orchestration for the `render` command. Recent updates have enabled AWS-based imports by correctly passing the environment to the preprocessor and added comprehensive integration tests for the template loading pipeline. While functional and well-tested, some opportunities remain for optimizing memory usage.

## Issues Found

### R1-1: AWS-based Imports Disabled (Critical)
**File**: src/Iidy/Render.hs:52
**What**: `runRender` previously passed `Nothing` to `mkFullDispatcher`.
**Status**: FIXED. `Main.hs` now creates an AWS environment from settings and passes it to `runRender`, which in turn enables AWS loaders in the import dispatcher.

### R1-2: Poor Error Granularity for JMESPath Queries (Minor)
**File**: src/Iidy/Render.hs:62
**What**: When a JMESPath query fails, the code discards the specific error message from `applyJmesPath` and prints a generic "Invalid JMESPath query" message. This makes it difficult for users to debug complex queries.
**Fix**: Capture the `Left msg` from `applyJmesPath` and include it in the error output.

### R1-3: Performance: Redundant Memory Copies (Minor)
**File**: src/Iidy/Render.hs:40, 46
**What**: The code converts `Lazy ByteString` to `Strict Text` multiple times (via `BL.toStrict` then `TE.decodeUtf8`). For very large CloudFormation templates, this can lead to high memory pressure and unnecessary CPU overhead.
**Fix**: Perform the decoding once and pass the `Text` or `ByteString` consistently through the pipeline.

### R1-4: Runtime Validation of Formats (Minor)
**File**: src/Iidy/Render.hs:71
**What**: `raFormat` is defined as `Text` in `Cli.hs` and validated at runtime using a list of strings (`["json", "yaml", ...]`). This is less type-safe than using an idiomatic Haskell sum type for formats.
**Fix**: Use a sum type (e.g., `OutputFormat`) in `RenderArgs` and handle it with a total case statement.

### R1-5: Missing Integration Tests for Command Logic (Major)
**File**: test/
**What**: Previously, there were no integration tests for the command orchestration.
**Status**: FIXED in commit b8233c3. Added a new `Test.TemplateLoaderTest` suite that comprehensively tests the `loadCfnTemplate` function, including URL passthrough, `render:` prefix preprocessing, environment injection, and error conditions like malformed YAML or oversized templates.

## Test Coverage Assessment
- **Gaps**: No tests for the render command's specific features (overwrite protection, format switching).
- **Gaps**: No tests for stdin/stdout handling in `render`.

## Positive Observations
- Correctly handles the `-` convention for both input and output paths.
- Integrates well with the enhanced error display subsystem for both parse and preprocess errors.
- Automatic YAML spec detection provides a seamless experience for users working with older templates.

## Grade Justification
- -15 points: Critical functional gap (AWS imports disabled).
- -10 points: Lack of integration tests for command-level logic.
- -3 points: Redundant memory copies.
- -2 points: Poor error granularity for queries.
