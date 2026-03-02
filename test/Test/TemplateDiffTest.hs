module Test.TemplateDiffTest (templateDiffTests) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (testCase, (@?=))

import Iidy.Cfn.Operations.TemplateApproval (generateDiff)

templateDiffTests :: [TestTree]
templateDiffTests =
  [ testCase "identical files produce empty diff" $
      generateDiff 3 "line1\nline2\nline3" "line1\nline2\nline3" @?= ""

  , testCase "identical empty strings produce empty diff" $
      generateDiff 3 "" "" @?= ""

  , testCase "single line change with context" $ do
      let old = "aaa\nbbb\nccc"
          new = "aaa\nBBB\nccc"
          result = generateDiff 3 old new
      -- Should show context around the change
      assertContains result "- bbb"
      assertContains result "+ BBB"
      assertContains result "  aaa"
      assertContains result "  ccc"

  , testCase "context=0 shows only changed lines" $ do
      let old = "aaa\nbbb\nccc\nddd\neee"
          new = "aaa\nBBB\nccc\nddd\nEEE"
          result = generateDiff 0 old new
      -- With 0 context, no Equal lines should appear
      assertNotContains result "  aaa"
      assertNotContains result "  ccc"
      assertNotContains result "  ddd"
      assertContains result "- bbb"
      assertContains result "+ BBB"
      assertContains result "- eee"
      assertContains result "+ EEE"

  , testCase "context=2 shows 2 lines of context around each hunk" $ do
      -- 10 lines, changes at line 1 (0-indexed) and line 8
      -- With context=2, these should be separate hunks
      let old = T.unlines ["L0","L1","L2","L3","L4","L5","L6","L7","L8","L9"]
          new = T.unlines ["L0","X1","L2","L3","L4","L5","L6","L7","X8","L9"]
          result = generateDiff 2 old new
      -- First hunk: context around L1->X1
      assertContains result "  L0"    -- 1 line before (index 0)
      assertContains result "- L1"
      assertContains result "+ X1"
      assertContains result "  L2"    -- context after
      assertContains result "  L3"    -- context after (2nd)
      -- Second hunk: context around L8->X8
      assertContains result "  L6"    -- context before
      assertContains result "  L7"    -- context before
      assertContains result "- L8"
      assertContains result "+ X8"
      assertContains result "  L9"    -- context after
      -- Hunks should be separated
      assertContains result "---"

  , testCase "large context (500) shows full file for small inputs" $ do
      let old = "aaa\nbbb\nccc\nddd\neee"
          new = "aaa\nBBB\nccc\nddd\neee"
          result = generateDiff 500 old new
      -- All lines should be visible as context
      assertContains result "  aaa"
      assertContains result "- bbb"
      assertContains result "+ BBB"
      assertContains result "  ccc"
      assertContains result "  ddd"
      assertContains result "  eee"
      -- No hunk separators needed (single hunk)
      assertNotContains result "---"

  , testCase "added lines at end" $ do
      let old = "aaa\nbbb"
          new = "aaa\nbbb\nccc"
          result = generateDiff 3 old new
      assertContains result "  aaa"
      assertContains result "  bbb"
      assertContains result "+ ccc"

  , testCase "removed lines at end" $ do
      let old = "aaa\nbbb\nccc"
          new = "aaa\nbbb"
          result = generateDiff 3 old new
      assertContains result "  aaa"
      assertContains result "  bbb"
      assertContains result "- ccc"

  , testCase "completely different content" $ do
      let old = "aaa\nbbb\nccc"
          new = "xxx\nyyy\nzzz"
          result = generateDiff 3 old new
      assertContains result "- aaa"
      assertContains result "- bbb"
      assertContains result "- ccc"
      assertContains result "+ xxx"
      assertContains result "+ yyy"
      assertContains result "+ zzz"

  , testCase "empty old (all additions)" $ do
      let old = ""
          new = "aaa\nbbb"
          result = generateDiff 3 old new
      assertContains result "+ aaa"
      assertContains result "+ bbb"

  , testCase "empty new (all deletions)" $ do
      let old = "aaa\nbbb"
          new = ""
          result = generateDiff 3 old new
      assertContains result "- aaa"
      assertContains result "- bbb"

  , testCase "adjacent hunks merge when context overlaps" $ do
      -- Changes at lines 1 and 3, with context=1 the ranges overlap
      let old = "L0\nL1\nL2\nL3\nL4"
          new = "L0\nX1\nL2\nX3\nL4"
          result = generateDiff 1 old new
      -- Should be a single hunk (no --- separator)
      assertNotContains result "---"
      assertContains result "- L1"
      assertContains result "+ X1"
      assertContains result "- L3"
      assertContains result "+ X3"

  , testCase "preserves line ordering in diff output" $ do
      let old = "first\nsecond\nthird"
          new = "first\nSECOND\nthird"
          result = generateDiff 3 old new
          lns = T.lines result
      -- Find the indices of the key lines
      let deleteIdx = findIndex' "- second" lns
          insertIdx = findIndex' "+ SECOND" lns
      -- Delete should come before insert
      case (deleteIdx, insertIdx) of
        (Just d, Just i) -> (d < i) @?= True
        _                -> fail "Expected both - second and + SECOND in output"

  , testCase "multi-line insertion in middle" $ do
      let old = "aaa\nbbb"
          new = "aaa\nx1\nx2\nx3\nbbb"
          result = generateDiff 3 old new
      assertContains result "+ x1"
      assertContains result "+ x2"
      assertContains result "+ x3"
      assertContains result "  aaa"
      assertContains result "  bbb"

  , testCase "multi-line deletion in middle" $ do
      let old = "aaa\nx1\nx2\nx3\nbbb"
          new = "aaa\nbbb"
          result = generateDiff 3 old new
      assertContains result "- x1"
      assertContains result "- x2"
      assertContains result "- x3"
      assertContains result "  aaa"
      assertContains result "  bbb"
  ]

-- | Assert that a text contains a given substring.
assertContains :: Text -> Text -> IO ()
assertContains haystack needle =
  if needle `T.isInfixOf` haystack
    then pure ()
    else fail $ "Expected output to contain " <> show needle
             <> " but got:\n" <> T.unpack haystack

-- | Assert that a text does NOT contain a given substring.
assertNotContains :: Text -> Text -> IO ()
assertNotContains haystack needle =
  if needle `T.isInfixOf` haystack
    then fail $ "Expected output to NOT contain " <> show needle
             <> " but got:\n" <> T.unpack haystack
    else pure ()

-- | Find the index of the first line containing a given substring.
findIndex' :: Text -> [Text] -> Maybe Int
findIndex' needle lns =
  case filter (\(_, l) -> needle `T.isInfixOf` l) (zip [0 :: Int ..] lns) of
    []        -> Nothing
    ((i,_):_) -> Just i
