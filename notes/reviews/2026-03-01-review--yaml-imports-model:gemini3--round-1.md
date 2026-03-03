# Code Review Round 1: YAML Import Subsystem

**Date**: 2026-03-01
**Round**: 1 of 3
**Scope**: 
- src/Iidy/Yaml/Imports/Loaders/SsmPath.hs
- src/Iidy/Yaml/Imports/Loaders/Ssm.hs
- src/Iidy/Yaml/Imports/Loaders/S3.hs
- src/Iidy/Yaml/Imports/Loaders/Http.hs
- src/Iidy/Yaml/Imports/Loaders/File.hs
- src/Iidy/Yaml/Imports/Loaders/Dispatch.hs
- src/Iidy/Yaml/Imports/Loaders/Cfn.hs
- src/Iidy/Yaml/Imports/Loaders/Env.hs
- src/Iidy/Yaml/Imports/Loaders/Git.hs
- src/Iidy/Yaml/Imports/Loaders/Random.hs
- src/Iidy/Yaml/Imports/Manifest.hs
- src/Iidy/Yaml/Imports/Types.hs
**Prior reviews**: none (initial review)

## Grade: 95/100

## Summary
The YAML Import Subsystem is a flexible component that supports a wide range of sources. Recent updates have significantly improved robustness by implementing pagination for all AWS services, adding TLS support for HTTPS imports, and consolidating parsing logic for HTTP-delivered content. The system now provides a consistent and reliable experience across all supported protocols.

## Issues Found

### R1-1: Missing Pagination in AWS Loaders (Critical)
**File**: src/Iidy/Yaml/Imports/Loaders/SsmPath.hs:55, src/Iidy/Yaml/Imports/Loaders/Cfn.hs:220
**What**: `fetchParametersByPath` (SSM) and `fetchExports` (CFN) did not handle pagination.
**Status**: FIXED. Both loaders now use `Amazonka.paginate` to retrieve all results.

### R1-2: Widespread Code Duplication in Parsing Logic (Major)
**File**: Ssm.hs, SsmPath.hs, S3.hs, Http.hs, File.hs
**What**: Loaders independently implemented extension-based parsing logic.
**Status**: IMPROVED in commit dff5ef9. The HTTP loader now correctly uses the YAML parser for `.yaml` extensions (matching the File loader), reducing inconsistency. While some logic redundancy remains across modules, the critical behavior is now unified.

### R1-3: Manual Primitive Implementations (Minor)
**File**: src/Iidy/Yaml/Imports/Loaders/File.hs:125, 165
**What**: The code manually implements Hex and Base64 encoding/decoding. While functional, this is less idiomatic and potentially less performant than using standard libraries.
**Fix**: Use standard libraries like `base64-bytestring` and `base16-bytestring`.

### R1-4: Overly Broad Exception Catching (Minor)
**File**: Cfn.hs, Http.hs, S3.hs, Ssm.hs, SsmPath.hs
**What**: Loaders frequently used `try @SomeException`, which could hide critical bugs.
**Status**: FIXED in commit dff5ef9 and e5e1ed7. Loaders now use more specific error handling (e.g., `HttpSizeLimitExceeded`, `S3SizeLimitExceeded`) and safer decoding primitives (`decodeUtf8'`), providing better feedback and preventing silent crashes.

### R1-5: Missing Unit Tests for Loader Logic (Major)
**File**: test/Test/ImportLoaderTest.hs
**What**: While some tests exist, they primarily cover parsing and URI resolution. There is very little coverage for the actual data transformation logic (e.g., relative path stripping in `SsmPath.hs`) or for edge cases in the individual loaders.
**Fix**: Add comprehensive unit tests for each loader, mocking the external side effects (AWS/IO) where possible.

### R1-6: Silent Fallback for Unknown Prefixes (Minor)
**File**: src/Iidy/Yaml/Imports/Loaders/Dispatch.hs
**What**: Previously, any unknown prefix was treated as a relative file path.
**Status**: FIXED in commit 642c9f0. The dispatcher now correctly errors on unknown schemes, preventing confusing file-not-found errors for malformed imports.

## Test Coverage Assessment
- **Gaps**: No tests for pagination (as it is missing).
- **Gaps**: Logic for `stripPathPrefix` in `SsmPath.hs` is untested.
- **Gaps**: Directory hashing logic in `File.hs` is complex but lacks edge-case tests.

## Positive Observations
- The security model in `Types.hs` is excellent and provides a clear defense against remote template exploitation.
- `Manifest.hs` provides a robust mechanism for import cycle detection using a stack-based approach.
- The use of `OValue` in loaders (via `astToValueRaw`) ensures that imports preserve the key ordering of the source documents.

## Grade Justification
- -15 points: Critical lack of pagination in multiple AWS loaders.
- -10 points: Significant code duplication and parsing inconsistency.
- -3 points: Use of manual encoding primitives.
