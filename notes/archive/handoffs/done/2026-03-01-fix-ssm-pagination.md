# Fix SSM GetParametersByPath Pagination (C-1)

**Status**: DONE
**Severity**: Critical
**Files**: `src/Iidy/Yaml/Imports/Loaders/SsmPath.hs`, `src/Iidy/Cfn/GlobalConfig.hs`

## Problem

Both `fetchParametersByPath` functions use `Amazonka.send` (single page) instead of
`Amazonka.paginate`. SSM returns max 10 params per page by default. If a user has >10
params under a path prefix, results are **silently truncated**.

The correct pattern already exists in `src/Iidy/Params/Client.hs:118`:
```haskell
pages <- runConduit $ Amazonka.paginate awsEnv req .| CL.consume
```

## Fix

1. In `SsmPath.hs` ~line 62-72: replace `Amazonka.send` with `Amazonka.paginate` + conduit consume, then concat all page parameters
2. In `GlobalConfig.hs` ~line 103-111: same fix
3. Add tests for multi-page results (mock the paginated response)

## Verification
- `cabal build` zero warnings
- `cabal test` all 972+ tests pass
- Add at least one test per file verifying pagination (>10 params)
