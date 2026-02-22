# Phase 8: Remaining Features (No Shortcuts)

**Status**: NOT STARTED
**Depends on**: Phase 7 (error display)

## Chunks

### 8.1: NTP Time Sync
- Critical for CI reliability — NOT optional
- Port from Rust's NTP implementation
- Implement minimal SNTP client (~100 LOC)
- **Verify**: time sync works, test with mock NTP server

### 8.2: Full Schema Validation
- Must match Rust's Draft 7 coverage exactly — no "minimal subset"
- Audit Rust's schema validation usage, implement all features used
- **Verify**: schema validation tests match Rust behavior

### 8.3: Demo Command
- Port full PTY handling from Rust (610 LOC)
- Masking, playback, recording
- **Verify**: demo command runs, snapshot tests if applicable

### 8.4: Property-Based Tests
- QuickCheck/hedgehog tests for parser
- **Verify**: property tests pass

### 8.5: Memory Profiling
- Verify memory usage under 512MB for typical operations
- **Verify**: `+RTS -s` output shows acceptable memory

## Gate Criteria
```bash
cabal build 2>&1 | grep -c warning  # must be 0
cabal test                            # all tests pass
# All features from Rust are present — no stubs, no undefined, no TODO
grep -r 'undefined\|error "TODO"\|error "Not implemented"' src/ | wc -l  # must be 0
```
