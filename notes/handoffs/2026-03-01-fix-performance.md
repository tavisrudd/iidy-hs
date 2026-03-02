# Fix OValue/Resolver Performance (M-1, M-2)

**Severity**: Medium
**File**: `src/Iidy/Yaml/OValue.hs`, `src/Iidy/Yaml/Resolution/Resolver.hs`

## M-1: lookupO is O(n) linear scan

`OValue.hs:106-109`: `lookupO` scans the association list linearly. Used in hot paths
like `resolveDotPathO`, `applyDotQueryValidated`, `resolveMapListToHash`, etc.

**Fix**: Add an `OMap` type that pairs the ordered `[(Text, OValue)]` with a
`Map Text OValue` for O(log n) lookups. Or add a `lookupO` that uses `Map.fromList`
on first call. Keep the ordered list for serialization, use the map for lookups.

**Alternative (simpler)**: If templates are typically small (<100 keys), document
that O(n) is acceptable and add a comment. Benchmark before optimizing.

## M-2: mergeOObjects O(n*m)

`Resolver.hs:599-609`: `notElem baseKeys` is O(n) per overlay key.

**Fix**: Use `Set.fromList baseKeys` for O(log n) membership checks. This is a
contained change: just add a Set import and convert baseKeys once.

## Verification
- `cabal build` zero warnings
- `cabal test` all 972+ tests pass
- Ensure OValue Eq instance still works
- Ensure key ordering is preserved in serialization
