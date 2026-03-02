# Audit and Update Stale Statistics in Documentation -- Maintenance

**Date**: 2026-03-01

## Context

The project's user-facing and developer docs reference module counts, test
counts, LOC counts, and other statistics that may be out of date. These
should be audited and updated to reflect the current state.

## What to Audit

Scan all files in `docs/` and `docs/dev/` for references to:
- Module counts (e.g., "81 modules", "80 modules")
- Test counts (e.g., "811 tests", "400 tests", "379 tests")
- LOC counts (e.g., "16,615 LOC")
- Any other numeric claims about project size/scope

## How to Get Current Values

- Module count: `find src -name '*.hs' | wc -l`
- Test count: `cabal test 2>&1 | grep -i "tests\|passed\|failed"` or check last test run
- LOC: `find src app -name '*.hs' | xargs wc -l | tail -1`

## Files to Check

- `docs/**/*.md`
- `docs/dev/**/*.md`
- `WORKPLAN.md` (if it references counts)
- `README.md` (if it exists)

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet
- **Why**: Research + find-and-replace. Read all docs, grep for numbers, verify
  against actuals, update.

## Progress

- [ ] Scan docs for stale statistics
- [ ] Get current module/test/LOC counts
- [ ] Update all stale references
- [ ] Build clean (no code changes expected)
