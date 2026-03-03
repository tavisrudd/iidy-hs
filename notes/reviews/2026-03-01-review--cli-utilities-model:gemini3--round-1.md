# Code Review Round 1: CLI & Utilities

**Date**: 2026-03-01
**Round**: 1 of 3
**Scope**: 
- src/Iidy/Cli.hs
- src/Iidy/Cli/Parser.hs
- src/Iidy/Confirm.hs
- src/Iidy/Demo.hs
- src/Iidy/Explain.hs
- src/Iidy/GetImport.hs
- src/Iidy/InitStackArgs.hs
- src/Iidy/Types.hs
**Prior reviews**: none (initial review)

## Grade: 90/100

## Summary
The CLI and Utility modules provide a robust user interface and a variety of helpful tools. Recent updates have significantly improved type safety by introducing dedicated sum-type readers for CLI arguments and enhanced performance by converting the error lookup system to use an efficient Map-based approach. The code is idiomatic and maintains high quality.

## Issues Found

### R1-1: Inconsistent Type Safety for CLI Flags (Minor)
**File**: src/Iidy/Cli/Parser.hs:380, 439, 456
**What**: Several flags previously used generic `Text` readers.
**Status**: FIXED in commit 7a1a18f. Dedicated sum types and `eitherReader` instances have been implemented for parameter types, output formats, and shell completion types, ensuring early validation during parsing.

### R1-2: Confirmation Prompt Ignores Global Color Settings (Minor)
**File**: src/Iidy/Confirm.hs:25
**What**: `requestConfirmation` hardcodes ANSI escape sequences for styling the prompt. This means colors will be shown even if the user specifies `--color never` or is in a non-TTY environment.
**Fix**: Pass the `ColorChoice` from `GlobalOpts` to the confirmation utility and respect the user's preference.

### R1-3: Linear Lookup for Error Explanations (Minor)
**File**: src/Iidy/Explain.hs:48
**What**: `lookupErrorCode` previously performed a linear search.
**Status**: FIXED in commit e00f3be. The error catalog is now converted into a `Data.Map` once at initialization, providing efficient O(log n) lookups.

### R1-4: Potential Dead Code in AWS Option Types (Minor)
**File**: src/Iidy/Cli.hs:56
**What**: The `NormalizedAwsOpts` record contains fields like `naoFixtureSet` that do not appear to be populated by the parser or used in the core logic. These may be vestiges of the original Rust implementation.
**Fix**: Conduct a dead-code audit and remove unused fields to simplify the internal AST.

### R1-5: Use of Partial Function `!!` (Minor)
**File**: src/Iidy/Yaml/Imports/Loaders/Random.hs
**What**: `randomElement` used `!!` for list indexing, which is partial.
**Fix**: Use total alternatives or explicit bounds checking.
**Status**: FIXED in commit b21afdd. Replaced with `drop` + pattern match.

## Test Coverage Assessment
- **Gaps**: `CliParserTest.hs` covers many branches but should be verified for completeness against all new sum-type readers.
- **Gaps**: `Demo.hs` and `Confirm.hs` lack unit tests due to their heavy reliance on IO and terminal interaction. Mocking these could improve reliability.

## Positive Observations
- `Demo.hs` uses `bracket` correctly to ensure resource cleanup (temporary directories) in all exit scenarios.
- The error catalog in `Explain.hs` is exceptionally well-written and provides great value to the user.
- The custom help rendering logic in `Parser.hs` provides a more tailored experience than the default `optparse-applicative` output.

## Grade Justification
- -5 points: Inconsistent type safety for CLI arguments.
- -5 points: Hardcoded ANSI styling in utilities.
- -3 points: Inefficient lookup logic.
- -5 points: Minor dead code and record proliferation.
