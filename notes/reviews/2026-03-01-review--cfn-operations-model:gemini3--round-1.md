# Code Review Round 1: CFN Stack Operations Subsystem

**Date**: 2026-03-01
**Round**: 1 of 3
**Scope**: 
- src/Iidy/Cfn/Operations/ConvertStack.hs
- src/Iidy/Cfn/Operations/CreateStack.hs
- src/Iidy/Cfn/Operations/UpdateStack.hs
- src/Iidy/Cfn/Operations/DeleteStack.hs
- src/Iidy/Cfn/Operations/Changeset.hs
- src/Iidy/Cfn/Operations/WatchStack.hs
- src/Iidy/Cfn/StackOperations.hs
- src/Iidy/Cfn/RequestBuilder.hs
- src/Iidy/Cfn/Types.hs
**Prior reviews**: none (initial review)

## Grade: 90/100

## Summary
The CFN operations subsystem is a robust and well-architected component. It features a clean separation of concerns between request construction, workflow management, and data conversion. Recent updates have significantly improved performance and correctness by implementing pagination for stack listing, parallelizing data collection, and optimizing event polling to use single-page fetches. The shared polling engine in `StackOperations.hs` is a highlight, providing a consistent experience for all stack-modifying commands.

## Issues Found

### R1-1: Inefficient Global Export Collection (Major: Performance)
**File**: src/Iidy/Cfn/StackOperations.hs:139-158
**What**: `collectStackContents` fetched *all* account-level exports using `ListExports` and filtered them client-side.
**Fix**: Replaced `ListExports` with derivation from stack outputs, matching Rust behavior and eliminating unnecessary API calls.
**Status**: FIXED in commit 7e04c3d.

### R1-2: Brittle String-Based Error Classification (Minor: Correctness)
**File**: src/Iidy/Cfn/StackOperations.hs:72, src/Iidy/Cfn/Operations/UpdateStack.hs:145
**What**: Functions like `isStackNotFoundError` and `isNoUpdatesError` rely on partial string matches in exception messages (e.g., "does not exist", "No updates are to be performed"). This is fragile as AWS can change these messages without notice.
**Fix**: Use more specific error codes or exception types provided by the Amazonka library if available, or at least consolidate these string constants into a central location for easier maintenance.

### R1-3: Circular Dependency Workarounds (Minor: Structure)
**File**: src/Iidy/Cfn/StackOperations.hs:253
**What**: `percentEncode` is placed in `StackOperations.hs` specifically to avoid circular dependencies between `Changeset.hs` and `DescribeStack.hs`. This is a suboptimal placement for a general-purpose utility.
**Fix**: Move `percentEncode` to a dedicated `Iidy.Util.Http` or similar utility module with no dependencies on the `Cfn` subsystem.

### R1-4: Silent Dropping of Unrecognized Capabilities (Minor: Correctness)
**File**: src/Iidy/Cfn/RequestBuilder.hs:143
**What**: `mapCapabilities` silently drops any capability strings it doesn't recognize. While it assumes upstream validation, it's safer to provide feedback when unexpected data is encountered.
**Fix**: Return an `Either` or at least log a warning when an unknown capability is encountered during request construction.

### R1-5: Sequential Parameterization in `ConvertStack` (Minor: Correctness)
**File**: src/Iidy/Cfn/Operations/ConvertStack.hs:71
**What**: `parameterizeEnv` uses a sequential fold for replacements. If a string contains multiple environment names (e.g., "testing-production"), it can result in double-replacement ("{{environment}}-{{environment}}"), which may be unintended.
**Fix**: Use a single-pass replacement strategy or explicitly handle overlapping/nested replacement cases if this behavior is problematic.

## Test Coverage Assessment
- **Gaps**: `ConvertStack.hs` has many internal helpers exported for testing, but comprehensive integration tests for the full conversion flow (including file system side effects) are limited.
- **Gaps**: Polling logic in `WatchStack.hs` and `StackOperations.hs` is difficult to unit test without complex AWS mocks.
- **Gaps**: The `DeleteStack` operation lacks dedicated unit tests in the current suite.

## Positive Observations
- The shared `pollForCompletion` engine is a very strong design pattern, ensuring that all operations (create, update, delete, watch) behave consistently.
- Idempotency is well-handled through the use of client request tokens and deterministic changeset naming.
- The YAML emitter in `ConvertStack.hs` is specialized for CloudFormation, ensuring that generated templates are well-structured and idiomatic.

## Grade Justification
- -10 points: Performance issue with global export collection.
- -5 points: Brittle string-based error classification.
- -5 points: Minor architectural and correctness issues (circular dependencies, silent capability dropping).
