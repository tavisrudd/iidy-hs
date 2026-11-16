# Re-enable 11 Skipped Error Fixture Tests -- Bug Fix Batch

**Status**: DONE
**Date**: 2026-03-01
**Session**: `00cdf3e0-e600-42b8-8b73-07f9dcd707ad`

## Context

`test/Test/ErrorFixtureTest.hs:22-33` has 11 error fixture tests filtered out. Each test
loads a YAML fixture, expects a preprocessing/parse error, and compares the formatted error
output against a Rust snapshot. These tests were skipped because the Haskell error output
doesn't yet match the Rust reference for these cases.

## Skipped Tests

| # | Test Name                          | Error Domain               |
|---|------------------------------------|-----------------------------|
| 1 | cloudformation-empty-arrays        | CFN validation              |
| 2 | cloudformation-null-value          | CFN validation              |
| 3 | cloudformation-wrong-element-count | CFN validation              |
| 4 | jmespath-query-and-jmespath-exclusive | Mutually exclusive fields |
| 5 | join-wrong-array-item-type         | Tag type validation         |
| 6 | query-missing-key                  | Variable/property lookup    |
| 7 | tag-if-unknown-field               | Tag field validation        |
| 8 | tag-mapvalues-unknown-field        | Tag field validation        |
| 9 | unknown-tag-typo-flow              | Tag recognition             |
| 10| unknown-tag-typo                   | Tag recognition             |
| 11| variable-not-found                 | Variable lookup             |

## Approach

For each skipped test:
1. Run the test to see current output vs expected snapshot
2. Diagnose why it doesn't match (missing classifier, wrong position, different message)
3. Fix the error pipeline to produce matching output
4. Remove from skip list

## Codebase Reference

| What                  | Where                                           |
|-----------------------|--------------------------------------------------|
| Skip list             | `test/Test/ErrorFixtureTest.hs:22-33`           |
| Error fixtures        | `test-fixtures/error-fixtures/`                  |
| Rust snapshots        | `~/src/iidy/tests/snapshots/`                    |
| Haskell snapshots     | `test-fixtures/error-expected/`                  |
| Error classifier      | `src/Iidy/Yaml/Errors/Conversion.hs`            |
| snapshot compare      | `scripts/error-snapshot-compare.sh`              |

## Delegation Strategy

- **Can delegate?** Yes, but each test may need different fixes
- **Sub-agent type**: Opus for investigation, Sonnet for mechanical fixes
- **Note**: Fix in small batches (3-4 at a time) to keep commits manageable

## Progress

- [ ] Investigate each skipped test (run, compare output)
- [ ] Fix error classifier/display for each case
- [ ] Remove from skip list, verify snapshots match
- [ ] All tests pass including re-enabled fixtures

## Handoff Notes

(to be filled by implementing session)

## Status Notes
Completed in commit 6d20b10 ("Re-enable 11 skipped error fixture tests"). Skip list removed from ErrorFixtureTest.hs.
