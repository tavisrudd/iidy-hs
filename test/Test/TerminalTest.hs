module Test.TerminalTest (terminalTests) where

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Iidy.Output.Terminal (resolveWidth)

terminalTests :: TestTree
terminalTests =
    testGroup
        "Output.Terminal width"
        [ testCase "valid COLUMNS wins over real size" $
            resolveWidth (Just "100") True (Just 200) @?= Just 100
        , testCase "valid COLUMNS wins when not a terminal" $
            resolveWidth (Just "100") False Nothing @?= Just 100
        , testCase "invalid COLUMNS falls through to real size" $
            resolveWidth (Just "abc") True (Just 200) @?= Just 200
        , testCase "zero COLUMNS falls through to real size" $
            resolveWidth (Just "0") True (Just 200) @?= Just 200
        , testCase "negative COLUMNS falls through to real size" $
            resolveWidth (Just "-5") True (Just 200) @?= Just 200
        , testCase "real size used when COLUMNS unset" $
            resolveWidth Nothing True (Just 200) @?= Just 200
        , testCase "terminal with no size and no COLUMNS is Nothing, not 80" $
            resolveWidth Nothing True Nothing @?= Nothing
        , testCase "real size of 0 (some ptys) falls through to Nothing" $
            resolveWidth Nothing True (Just 0) @?= Nothing
        , testCase "COLUMNS that overflows Int is rejected, not wrapped" $
            resolveWidth (Just "18446744073709551716") True (Just 200) @?= Just 200
        , testCase "COLUMNS above the sane bound is rejected" $
            resolveWidth (Just "10001") True (Just 200) @?= Just 200
        , testCase "COLUMNS at the sane bound is accepted" $
            resolveWidth (Just "10000") True (Just 200) @?= Just 10000
        , testCase "non-terminal without COLUMNS is Nothing" $
            resolveWidth Nothing False (Just 200) @?= Nothing
        ]
