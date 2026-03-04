module Iidy.Cli.HelpTest (tests) where

import Data.List (isInfixOf)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Cli.Help (
    formatRowsForTest,
    formatUsageLine,
    helpDescriptionForTest,
 )

tests :: TestTree
tests =
    testGroup
        "Cli.Help"
        [ testCase "formatUsageLine adds options placeholder when needed" $
            formatUsageLine "Usage: iidy-hs create-stack [--stack-name NAME] ARGSFILE"
                @?= "iidy-hs create-stack [OPTIONS] ARGSFILE"
        , testCase "formatUsageLine leaves command without options untouched" $
            formatUsageLine "Usage: iidy-hs demo DEMOSCRIPT"
                @?= "iidy-hs demo DEMOSCRIPT"
        , testCase "formatUsageLine keeps explicit placeholders" $
            formatUsageLine "Usage: iidy-hs command [--flag] <REQUIRED> [OPTIONAL]"
                @?= "iidy-hs command [OPTIONS] <REQUIRED> [OPTIONAL]"
        , testCase "formatRowsForTest wraps and highlights placeholders" $ do
            let rows =
                    [ ("--flag", "Toggle something important")
                    , ("ARGFILE", "Required positional argument")
                    ]
                rendered = formatRowsForTest 60 rows
            case rendered of
                [flagLine, argLine] -> do
                    assertBool "flag description present" ("Toggle something important" `isInfixOf` flagLine)
                    assertBool "arg description present" ("Required positional argument" `isInfixOf` argLine)
                    assertBool "placeholder wrapped in angle brackets" ("<ARGFILE>" `isInfixOf` argLine)
                other ->
                    assertFailure ("expected two help lines, got: " <> show other)
        , testCase "helpDescriptionForTest finds parent and subcommand descriptions" $ do
            helpDescriptionForTest ["create-stack"]
                @?= Just "create a cfn stack based on stack-args.yaml"
            helpDescriptionForTest ["param", "set"]
                @?= Just "set a parameter value"
            helpDescriptionForTest ["param", "unknown"]
                @?= Nothing
        ]
