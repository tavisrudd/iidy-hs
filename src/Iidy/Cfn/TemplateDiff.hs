{- | Line diff between two template versions, shown by
@template-approval review@.
-}
module Iidy.Cfn.TemplateDiff (
    generateDiff,
) where

import Data.Array qualified as Array
import Data.List qualified as List
import Data.Text (Text)
import Data.Text qualified as T

-- | A single diff operation.
data DiffOp
    = -- | Line present in both old and new
      Equal !Text
    | -- | Line removed from old
      Delete !Text
    | -- | Line added in new
      Insert !Text

{- | Generate a unified-style line diff between old and new content.
Shows @contextLines@ lines of context around each change group.
Non-adjacent hunks are separated by @---@.
Returns empty text when the inputs are identical.
-}
generateDiff :: Int -> Text -> Text -> Text
generateDiff contextLines old new
    | old == new = ""
    | otherwise =
        let oldLns = T.lines old
            newLns = T.lines new
            ops = lcsOps oldLns newLns
            hunks = buildHunks contextLines ops
         in formatHunks hunks

{- | Compute the LCS table via dynamic programming, then backtrack to
produce a list of 'DiffOp' values that transform old into new.
-}
lcsOps :: [Text] -> [Text] -> [DiffOp]
lcsOps oldLns newLns =
    let m = length oldLns
        n = length newLns
        oldArr = Array.listArray (0, m - 1) oldLns
        newArr = Array.listArray (0, n - 1) newLns
        -- dp ! (i, j) = LCS length for oldLns[i..] vs newLns[j..]
        dp :: Array.Array (Int, Int) Int
        dp =
            Array.array
                ((0, 0), (m, n))
                [ ((i, j), val i j)
                | i <- [0 .. m]
                , j <- [0 .. n]
                ]
        val :: Int -> Int -> Int
        val i j
            | i == m || j == n = 0
            | oldArr Array.! i == newArr Array.! j = 1 + dp Array.! (i + 1, j + 1)
            | otherwise = max (dp Array.! (i + 1, j)) (dp Array.! (i, j + 1))
        -- Backtrack to produce diff ops
        backtrack :: Int -> Int -> [DiffOp]
        backtrack i j
            | i == m && j == n = []
            | i == m = Insert (newArr Array.! j) : backtrack i (j + 1)
            | j == n = Delete (oldArr Array.! i) : backtrack (i + 1) j
            | oldArr Array.! i == newArr Array.! j =
                Equal (oldArr Array.! i) : backtrack (i + 1) (j + 1)
            | dp Array.! (i + 1, j) >= dp Array.! (i, j + 1) =
                Delete (oldArr Array.! i) : backtrack (i + 1) j
            | otherwise =
                Insert (newArr Array.! j) : backtrack i (j + 1)
     in backtrack 0 0

-- | A hunk is a contiguous group of diff lines to display.
type Hunk = [DiffOp]

{- | Build hunks from a flat list of diff ops, using @ctx@ lines of
context around each change.
-}
buildHunks :: Int -> [DiffOp] -> [Hunk]
buildHunks ctx ops =
    let indexed = zip [0 :: Int ..] ops
        -- Indices of non-Equal ops
        changeIdxs = [i | (i, op) <- indexed, isChange op]
     in case changeIdxs of
            [] -> [] -- no changes
            _hasChanges ->
                let
                    -- Expand each change index into a range [lo..hi] with context
                    ranges =
                        map
                            (\i -> (max 0 (i - ctx), min (totalLen - 1) (i + ctx)))
                            changeIdxs
                    -- Merge overlapping/adjacent ranges
                    merged = mergeRanges ranges
                 in
                    -- Extract hunks from merged ranges
                    map (extractHunk indexed) merged
  where
    totalLen :: Int
    totalLen = length ops

    isChange :: DiffOp -> Bool
    isChange (Equal _) = False
    isChange _ = True

    mergeRanges :: [(Int, Int)] -> [(Int, Int)]
    mergeRanges [] = []
    mergeRanges (r : rs) = List.foldl' merge1 [r] rs

    merge1 :: [(Int, Int)] -> (Int, Int) -> [(Int, Int)]
    merge1 [] r = [r]
    merge1 acc (lo, hi) =
        case reverse acc of
            [] -> [(lo, hi)]
            (prevLo, prevHi) : rest
                | lo <= prevHi + 1 -> reverse rest ++ [(prevLo, max prevHi hi)]
                | otherwise -> acc ++ [(lo, hi)]

    extractHunk :: [(Int, DiffOp)] -> (Int, Int) -> Hunk
    extractHunk indexed (lo, hi) =
        [op | (i, op) <- indexed, i >= lo, i <= hi]

{- | Format hunks into the final text output. Non-adjacent hunks are
separated by a @---@ line.
-}
formatHunks :: [Hunk] -> Text
formatHunks [] = ""
formatHunks hunks =
    let formatted = map formatHunk hunks
     in T.intercalate "\n---\n" formatted

-- | Format a single hunk.
formatHunk :: Hunk -> Text
formatHunk ops = T.intercalate "\n" (map formatOp ops)

-- | Format a single diff operation.
formatOp :: DiffOp -> Text
formatOp (Equal l) = "  " <> l
formatOp (Delete l) = "- " <> l
formatOp (Insert l) = "+ " <> l
