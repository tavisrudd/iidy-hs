# Phase 9: Final Verification

**Status**: NOT STARTED
**Depends on**: Phase 7, Phase 8

## Chunks

### 9.1: Full Snapshot Comparison
- All 98 Rust snapshot files produce identical output from Haskell
- **Verify**: `scripts/snapshot-compare.sh` 36/36, `scripts/error-snapshot-compare.sh` 49/49, remaining 13 snapshots

### 9.2: CLI Help Parity
- `iidy-hs --help` structure matches `iidy --help`
- Every subcommand help matches
- **Verify**: diff help output

### 9.3: Feature Completeness Audit
- Compare every Rust module against Haskell equivalent
- No stubs, no undefined, no TODO, no dropped features
- **Verify**: `grep -r 'undefined\|TODO\|STUB\|FIXME' src/` returns nothing

### 9.4: Nix Build
- `nix build` produces working binary
- **Verify**: `nix build && result/bin/iidy-hs --help`

## Gate Criteria (FINAL)
```bash
nix build                              # clean build
cabal test                             # all tests pass
scripts/snapshot-compare.sh            # 36/36
scripts/error-snapshot-compare.sh      # 49/49
grep -r 'undefined\|TODO\|STUB' src/   # nothing
result/bin/iidy-hs --help              # works
```
