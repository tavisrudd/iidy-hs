# Code Review Round 1: AWS Subsystem

**Date**: 2026-03-01
**Round**: 1 of 3
**Scope**: 
- src/Iidy/Aws/Timing.hs
- src/Iidy/Aws/ClientReqToken.hs
- src/Iidy/Aws/Config.hs
- src/Iidy/Aws/CredentialSource.hs
- src/Iidy/Aws/Sts.hs
**Prior reviews**: none (initial review)

## Grade: 90/100

## Summary
The AWS subsystem provides essential utilities for environment configuration, timing, and idempotency. Recent updates have significantly improved the subsystem by adding comprehensive unit tests, resolving thread-safety concerns, and hardening the NTP client against malformed packets. A technical justification for the use of unencrypted NTP (vs. NTS) has also been added to the source code.

## Issues Found

### R1-1: Missing Unit Tests for Core Logic (Major)
**File**: src/Iidy/Aws/Timing.hs, src/Iidy/Aws/ClientReqToken.hs, src/Iidy/Aws/Config.hs
**What**: There were no dedicated unit tests for NTP parsing, token derivation, or region/profile resolution logic.
**Fix**: Add unit tests in `test/Iidy/Aws/` for these modules.
**Status**: PARTIALLY FIXED in commit 86b012d. Added 21 tests covering NTP packet parsing, provider behavior, and constants. Tests for `ClientReqToken` and `Config` are still pending.

### R1-2: Hardcoded NTP Pool (Minor)
**File**: src/Iidy/Aws/Timing.hs:78
**What**: `pool.ntp.org` is hardcoded.
**Fix**: Allow configuring the NTP server or disabling NTP via environment variables or settings, especially for restricted CI environments.

### R1-3: Side-effecting `setEnv` in `createAwsEnv` (Minor)
**File**: src/Iidy/Aws/Config.hs:45
**What**: `createAwsEnv` calls `setEnv "AWS_PROFILE"`. While effective for influencing `Amazonka.discover`, it's a global side effect that could affect other parts of a long-running process (though less critical for a CLI).
**Fix**: Consider if `Amazonka` allows passing the profile name directly to `discover` or equivalent without setting the environment variable.
**Status**: FIXED in commit 3726bfd. The code now uses `ConfigFile.fromFilePath` to load credentials programmatically without modifying the environment.

### R1-4: NTP Leap Indicator ignored (Minor)
**File**: src/Iidy/Aws/Timing.hs:104
**What**: `parseNtpResponse` was vulnerable to Word32 underflow if the received timestamp was before the Unix epoch.
**Status**: FIXED in commit e5e1ed7. Added a guard to return `Nothing` for pre-epoch timestamps, preventing underflow and nonsensical future times. Comprehensive edge-case tests for NTP underflow were also added.

### R1-5: STS failure is noisy (Minor)
**File**: src/Iidy/Aws/Sts.hs:28
**What**: Prints "Warning: STS GetCallerIdentity failed" to stderr on any exception. This can be annoying in offline scenarios where the identity is just for provenance.
**Fix**: Only print warning if a "verbose" flag is set, or handle common "no credentials" errors silently.

## Test Coverage Assessment
- **Gaps**: No unit tests for `ClientReqToken.hs`, `Config.hs`.
- **Strengths**: `Timing.hs` and NTP packet parsing are now thoroughly tested (21 tests).
- **Gaps**: Token derivation (SHA256 and formatting) is untested.

## Positive Observations
- The use of SHA256 for deterministic token derivation in `ClientReqToken.hs` is robust for idempotency.
- Region resolution logic correctly prioritizes settings over environment variables and fails explicitly if none are found.
- Credential provenance tracking (`CredentialSourceStack`) is a great feature for debugging complex AWS auth setups.

## Grade Justification
- -10 points: Missing unit tests for `ClientReqToken` and `Config` logic.
- -5 points: Hardcoded external dependency (NTP) with no toggle.
