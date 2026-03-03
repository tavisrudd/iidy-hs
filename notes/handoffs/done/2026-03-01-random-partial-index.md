# Replace Partial `!!` in Random.hs with Total Indexing -- Bug Fix

**Status**: DONE
**Date**: 2026-03-01
**References**: `src/Iidy/Yaml/Imports/Loaders/Random.hs:45`, CLAUDE.md ("No partial functions")

## Context

`Random.hs` line 45 uses `!!` (partial list index) which crashes on empty lists
or out-of-bounds indices. The CLAUDE.md coding standards explicitly prohibit
partial functions (`head`, `tail`, `fromJust`, `!!`).

```haskell
randomElement :: [Text] -> IO Text
randomElement xs = do
  i <- randomRIO (0, Prelude.length xs - 1)
  pure (xs !! i)
```

While the callers always pass non-empty hardcoded lists (adjectives, nouns), the
function signature accepts any list. An empty list would cause `randomRIO (0, -1)`
which has undefined behavior, and `[] !! 0` would crash.

## Fix

### Option A: Use Data.Vector (recommended if lists are static)

Convert the word lists to Vectors for O(1) indexing with bounds checking:

```haskell
import qualified Data.Vector as V

randomElement :: V.Vector Text -> IO Text
randomElement vec
  | V.null vec = pure ""  -- or error, but shouldn't happen
  | otherwise = do
      i <- randomRIO (0, V.length vec - 1)
      pure (vec V.! i)  -- still partial, but...
```

Actually, `V.!` is also partial. Use `V.unsafeIndex` with the guard, or just
use safe indexing.

### Option B: Safe list indexing with NonEmpty (cleanest)

```haskell
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE

randomElement :: NonEmpty Text -> IO Text
randomElement xs = do
  let len = NE.length xs
  i <- randomRIO (0, len - 1)
  pure (NE.toList xs !! i)  -- still partial...
```

### Option C: Safe indexing helper (simplest, recommended)

Keep lists, add a safe index:

```haskell
randomElement :: [Text] -> IO Text
randomElement [] = pure ""
randomElement xs = do
  i <- randomRIO (0, length xs - 1)
  pure $ fromMaybe "" (listSafeIndex xs i)

listSafeIndex :: [a] -> Int -> Maybe a
listSafeIndex xs i
  | i < 0 || i >= length xs = Nothing
  | otherwise = Just (xs !! i)
```

Or even simpler — just guard the empty case and use `!!` knowing bounds are valid:

### Option D: Simplest total fix (recommended)

```haskell
randomElement :: [Text] -> IO Text
randomElement [] = pure ""
randomElement xs = do
  i <- randomRIO (0, length xs - 1)
  case drop i xs of
    (x:_) -> pure x
    []    -> pure ""  -- unreachable given bounds, but total
```

`drop i xs` followed by pattern match is total. No `!!` needed. The empty case
is unreachable given the `randomRIO` bounds but satisfies the totality requirement.

## Codebase Reference

| What              | Where                                        |
|-------------------|----------------------------------------------|
| `randomElement`   | `src/Iidy/Yaml/Imports/Loaders/Random.hs:42` |
| adjectives list   | `src/Iidy/Yaml/Imports/Loaders/Random.hs:47` |
| nouns list        | `src/Iidy/Yaml/Imports/Loaders/Random.hs:57` |
| Existing tests    | `test/Test/ImportLoaderTest.hs` (randomTests) |

## Build/Test Commands

Per CLAUDE.md.

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet (or even Haiku)
- **Why**: 3-line change in one function. Use Option D (drop+pattern match).

## Progress

- [ ] Replace `!!` with total indexing in `randomElement`
- [ ] Build clean + all tests pass (existing random tests cover this)
