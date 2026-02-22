# Phase 8: Remaining Features (No Shortcuts)

**Status**: DONE — 8.1, 8.2, 8.3, 8.4, 8.5, 8.6 complete
**Depends on**: Phase 7 (error display)

## Chunks

### 8.1: NTP Time Sync — DONE
- [x] SNTP client (RFC 4330) querying pool.ntp.org
- [x] 2-second timeout, retry once, fallback to system time
- [x] `reliableTimeProvider` for write ops, `systemTimeProvider` for read-only
- [x] Wired into Main.hs via `timeProviderForOperation`

### 8.2: Full Schema Validation — DONE
- [x] Custom JSON Schema Draft 7 validator (~170 LOC)
- [x] Keywords: type, required, properties, items, pattern, minimum/maximum, minItems/maxItems, minLength/maxLength, enum, additionalProperties
- [x] AllowedPattern now does regex matching via regex-posix
- [x] Object type validation added, unknown types produce errors
- [x] Schema validation wired into param validation pipeline
- [x] 16 tests for JsonSchema validator

### 8.3: Demo Command — DONE
- [x] Full port of Rust demo.rs (610 LOC → ~250 LOC Haskell)
- [x] Shell commands with character-by-character typing display
- [x] Silent execution, sleep (with timescaling), setenv, banner
- [x] AWS account number masking (12-digit sequences)
- [x] iidy command substitution (detects exe path differences)
- [x] YAML preprocessing via preprocessYaml11
- [x] Temp dir file unpacking with path safety
- [x] No more `notImplemented` stubs in codebase

### 8.4: Property-Based Tests — DONE
- [x] QuickCheck + tasty-quickcheck added as dependencies
- [x] 6 property tests: OValue round-trip, null/bool/string preservation, parse/emit stability, handlebars passthrough
- [x] All 100 iterations pass per property
- **Verify**: property tests pass ✓

### 8.5: Memory Profiling — DONE
- [x] Verified via `+RTS -s`: 316 KB max residency, ~125 MiB total (well under 512MB)
- **Verify**: `+RTS -s` output shows acceptable memory ✓

### 8.6: Unchecked Gate Items from Phases 1-6 — DONE
- [x] Property tests for parser (Gate 2 deferral) — done in 8.4
- [x] Mock/fixture unit tests for CFN request building (Gate 4) — 20 RequestBuilder tests
- [x] `watch-stack` streams mock events (Gate 4) — pollForCompletionWith with DI, 6 tests (terminal detection, multi-poll, dedup, nested resource filtering)
- [x] `delete-stack` confirmation logic test (Gate 4) — pure `isConfirmation` function, 10 tests
- [x] Changeset conversion tests (Gate 4) — `convertChange`/`convertDetail` unit tests, 7 tests
- [x] Shell completion works for bash/zsh (Gate 5) — hardcoded scripts exist, tested via CLI parser

## Gate Criteria
```bash
cabal build 2>&1 | grep -c warning  # must be 0
cabal test                            # all tests pass
# All features from Rust are present — no stubs, no undefined, no TODO
grep -r 'undefined\|error "TODO"\|error "Not implemented"' src/ | wc -l  # must be 0
```
