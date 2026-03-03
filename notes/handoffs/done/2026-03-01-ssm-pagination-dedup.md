# SSM Params: Pagination + Dedup + Error Handling -- Bug Fix Batch

**Status**: DONE
**Date**: 2026-03-01
**Session**: `00cdf3e0-e600-42b8-8b73-07f9dcd707ad`
**References**: Gemini review R1-1, R1-3, R1-4; Rust `~/src/iidy/src/params/`

## Context

Code review found three related issues in `Iidy.Params.Client` and `Iidy.Params.Review`:
- **R1-1 (Critical)**: `fetchByPath` and `fetchHistory` don't paginate — silently truncates at page size
- **R1-3 (Minor)**: `Review.hs` duplicates `fetchParam` from `Client.hs`
- **R1-4 (Minor)**: All ops catch `SomeException` — loses error specificity

Both SSM types (`GetParametersByPath`, `GetParameterHistory`) have `AWSPager` instances,
so we can use `Amazonka.paginate` with conduit (same pattern as CFN ops in the project).

## Issues to Fix

### A. Pagination (R1-1, Critical)

**Files**: `src/Iidy/Params/Client.hs:102-110` (fetchByPath), `src/Iidy/Params/Client.hs:132-138` (fetchHistory)

**Current**: Single `Amazonka.send` — returns only first page.

**Fix**: Replace `Amazonka.send` with `Amazonka.paginate` + conduit, matching existing pattern:
```haskell
import Data.Conduit (runConduit, (.|))
import qualified Data.Conduit.List as CL

fetchByPath awsEnv args = runResourceT $ do
  let req = (GPBP.newGetParametersByPath args.gpbPath)
              { GPBP.recursive      = Just args.gpbRecursive
              , GPBP.withDecryption = Just args.gpbDecrypt
              }
  pages <- runConduit $ Amazonka.paginate awsEnv req .| CL.consume
  let params = concatMap (fromMaybe [] . (.parameters)) pages
  pure (map formatParam params)
```

Same pattern for `fetchHistory`.

### B. Dedup fetchParam (R1-3, Minor)

**Files**: `src/Iidy/Params/Client.hs:47-52`, `src/Iidy/Params/Review.hs:81-87`

**Current**: Both modules have a `fetchParam` helper doing `GP.newGetParameter` + send.

**Fix**:
1. Export `fetchParam` from `Client.hs` (rename to return `Either Text Text` like Review's version)
2. Remove `fetchParam` from `Review.hs`, import from `Client.hs`
3. The Client version should handle `SomeException` internally (like Review's does)

### C. Error context (R1-4, Minor)

**Files**: All `try @SomeException` sites in both modules.

**Current**: `catch SomeException` → `T.pack (show ex)` loses structured info.

**Fix**: Keep `SomeException` catch (amazonka errors are diverse), but improve the message format
to include the operation name consistently. This is a minor polish — the Rust version also
converts errors to strings at this layer.

## Codebase Reference

| What                      | Where                                          |
|---------------------------|-------------------------------------------------|
| Client module             | `src/Iidy/Params/Client.hs` (150 LOC)          |
| Review module             | `src/Iidy/Params/Review.hs` (107 LOC)          |
| Pagination pattern (CFN)  | `src/Iidy/Cfn/StackOperations.hs:117-120`       |
| CLI arg types             | `src/Iidy/Cli.hs:226-237`                       |
| Conduit deps              | Already in cabal: `conduit`, `resourcet`         |
| AWSPager instances        | Confirmed for both GetParametersByPath and GetParameterHistory |

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — mechanical changes following established patterns
- **Isolation**: Worktree (parallel with other SSM fix)

## Progress

- [ ] A: Add pagination to fetchByPath and fetchHistory
- [ ] B: Export fetchParam from Client.hs, remove dupe from Review.hs
- [ ] C: Improve error messages with operation context
- [ ] Build clean, all tests pass

## Handoff Notes

(to be filled by implementing session)

## Status Notes
Completed in commit 826c295 ("Add SSM pagination + deduplicate fetchParam"). R1-1 pagination converted to Amazonka.paginate + conduit. R1-3 dedup resolved. R1-4 error context improved. Exception catch narrowed in c972b32.
