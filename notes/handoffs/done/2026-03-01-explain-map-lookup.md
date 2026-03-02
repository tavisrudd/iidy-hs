# Convert Explain.hs to Map Lookup -- Minor Optimization

**Date**: 2026-03-01
**Session**: `00cdf3e0-e600-42b8-8b73-07f9dcd707ad`

## Context

`src/Iidy/Explain.hs` uses `filter` over a 53-entry list for error code lookup.
Convert to `Data.Map` for O(log n) lookups and cleaner code.

## Current (lines 40-45)

```haskell
lookupErrorCode :: Text -> Maybe ErrorEntry
lookupErrorCode raw =
  let normalised = normaliseCode raw
  in case filter (\e -> ecCode e == normalised) allErrors of
       (e:_) -> Just e
       []    -> Nothing
```

## Target

```haskell
import qualified Data.Map.Strict as Map

errorMap :: Map Text ErrorEntry
errorMap = Map.fromList [(ecCode e, e) | e <- allErrors]

lookupErrorCode :: Text -> Maybe ErrorEntry
lookupErrorCode raw = Map.lookup (normaliseCode raw) errorMap
```

## Codebase Reference

| What           | Where                          |
|----------------|--------------------------------|
| Explain module | `src/Iidy/Explain.hs` (342 LOC) |
| lookupErrorCode | `src/Iidy/Explain.hs:40-45`   |
| allErrors list  | `src/Iidy/Explain.hs:75-342`  |
| 53 error entries | 9 categories (1xxx-9xxx)      |

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — trivial change
- **Note**: ~5 lines changed total

## Progress

- [ ] Convert allErrors list to Map
- [ ] Update lookupErrorCode to use Map.lookup
- [ ] Build clean, all tests pass

## Handoff Notes

(to be filled by implementing session)
