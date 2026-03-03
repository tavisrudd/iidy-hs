# Code Review Round 1: YAML Resolution Engine & Error Subsystem

**Date**: 2026-03-01
**Round**: 1 of 3
**Scope**: 
- src/Iidy/Yaml/Resolution/Resolver.hs
- src/Iidy/Yaml/Errors/Conversion.hs
- src/Iidy/Yaml/Errors/Display.hs
- src/Iidy/Yaml/Errors/Ids.hs
**Prior reviews**: none (initial review)

## Grade: 90/100

## Summary
The YAML Resolution Engine and Error Subsystem are sophisticated and provide a high degree of compatibility with the original Rust implementation. Recent updates have significantly improved the maintainability of the error subsystem and restored full confidence in its correctness by re-enabling all previously skipped error fixture tests. The system is now robust and well-verified.

## Issues Found

### R1-1: Fragile Error Classification via String Matching (Major)
**File**: src/Iidy/Yaml/Errors/Conversion.hs
**What**: Extensive reliance on `T.isPrefixOf` and `T.isInfixOf` to map error messages to Error IDs.
**Status**: PARTIALLY FIXED in commit 6c2a7ef. The module has been refactored into a cleaner hierarchy (`Conversion/Guidance.hs`, `Conversion/LineSearch.hs`, `Conversion/Location.hs`), and more cases use structured matching on `ResolveErrorKind`. However, the `classifyMessage'` dispatcher still performs significant string matching for many error types.

### R1-2: Significant Gaps in Error Fixture Tests (Major)
**File**: test/Test/ErrorFixtureTest.hs:22
**What**: Previously, eleven error fixture tests were explicitly skipped.
**Status**: FIXED in commit 6d20b10. All 11 error fixture tests (including CloudFormation validation, variable lookups, and tag typos) have been re-enabled and are passing, ensuring full parity with the reference implementation's error behavior.

### R1-3: Complex Location Heuristics (Minor)
**File**: src/Iidy/Yaml/Errors/Conversion.hs:515 (adjustLocationForTag)
**What**: The logic to adjust source locations to point at tags instead of values is very complex and relies on manual string searching in the source lines. While this achieves Rust compatibility, it is error-prone.
**Fix**: Consider if the AST or Parser can be updated to provide the exact tag position more directly, reducing the need for "nearby line" heuristics.

### R1-4: Potential Fidelity Loss in `!$parseYaml` (Minor)
**File**: src/Iidy/Yaml/Resolution/Resolver.hs
**What**: When parsing YAML or JSON strings via tags, the results are often converted through `Aeson.Value` or generic maps. This might lose ordering or specific YAML type information (like merge keys) that the rest of the engine preserves via `OValue`.
**Fix**: Ensure internal parsing tags use `OValue`-aware parsers where possible.

## Test Coverage Assessment
- **Gaps**: 11 skipped integration tests in `ErrorFixtureTest.hs`.
- **Gaps**: Unit tests for `Conversion.hs` (classification logic) are present in `ErrorClassificationTest.hs` but may not cover all string-matching branches.

## Positive Observations
- `ResolveErrorKind` is an excellent abstraction for carrying semantic error information across the resolution boundary.
- The `Display.hs` module produces very high-quality, user-friendly error messages with source code snippets and carets.
- The system handles complex YAML features (like custom resource expansion) while maintaining source location tracking.

## Grade Justification
- -10 points: Fragility of string-based error classification.
- -10 points: 11 skipped critical error fixture tests.
- -2 points: Complexity and potential brittleness of location-adjustment heuristics.
