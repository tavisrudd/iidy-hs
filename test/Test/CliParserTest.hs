module Test.CliParserTest (cliParserTests) where

import Options.Applicative (execParserPure, prefs, showHelpOnEmpty, ParserResult(..))
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Cli (Cli(..), Commands(..), GlobalOpts(..), AwsOpts(..), DeleteArgs(..), DescribeArgs(..), RenderArgs(..))
import Iidy.Cli.Parser (cliParserInfo)
import Iidy.Types (ColorChoice(..), Theme(..), YamlSpec(..))

-- | Helper to parse CLI args using optparse-applicative in pure mode
parseCli :: [String] -> Either String Cli
parseCli args = case execParserPure (prefs showHelpOnEmpty) cliParserInfo args of
  Success cli -> Right cli
  Failure _   -> Left "parse failure"
  _           -> Left "unexpected result"

cliParserTests :: [TestTree]
cliParserTests =
  [ testCase "parse describe-stack" $ do
      case parseCli ["describe-stack", "my-stack"] of
        Left e -> assertFailure e
        Right cli -> case cliCommand cli of
          CmdDescribeStack args -> do
            daStackname args @?= "my-stack"
            daEvents args @?= 50
          _ -> assertFailure "Expected CmdDescribeStack"

  , testCase "parse describe-stack with events" $ do
      case parseCli ["describe-stack", "my-stack", "--events", "25"] of
        Left e -> assertFailure e
        Right cli -> case cliCommand cli of
          CmdDescribeStack args -> do
            daStackname args @?= "my-stack"
            daEvents args @?= 25
          _ -> assertFailure "Expected CmdDescribeStack"

  , testCase "parse render with defaults" $ do
      case parseCli ["render", "template.yaml"] of
        Left e -> assertFailure e
        Right cli -> case cliCommand cli of
          CmdRender args -> do
            raTemplate args @?= "template.yaml"
            raOutfile args @?= "stdout"
            raFormat args @?= "yaml"
            raOverwrite args @?= False
            raYamlSpec args @?= YamlAuto
          _ -> assertFailure "Expected CmdRender"

  , testCase "parse render with options" $ do
      case parseCli ["render", "t.yaml", "--format", "json", "--overwrite", "--yaml-spec", "1.1"] of
        Left e -> assertFailure e
        Right cli -> case cliCommand cli of
          CmdRender args -> do
            raFormat args @?= "json"
            raOverwrite args @?= True
            raYamlSpec args @?= YamlV11
          _ -> assertFailure "Expected CmdRender"

  , testCase "parse delete-stack with --yes" $ do
      case parseCli ["delete-stack", "doomed-stack", "--yes"] of
        Left e -> assertFailure e
        Right cli -> case cliCommand cli of
          CmdDeleteStack args -> do
            delStackname args @?= "doomed-stack"
            delYes args @?= True
            delFailIfAbsent args @?= False
          _ -> assertFailure "Expected CmdDeleteStack"

  , testCase "parse global options" $ do
      case parseCli ["-e", "staging", "--color", "never", "--theme", "light", "--debug", "explain", "ERR_2001"] of
        Left e -> assertFailure e
        Right cli -> do
          goEnvironment (cliGlobalOpts cli) @?= "staging"
          goColor (cliGlobalOpts cli) @?= ColorNever
          goTheme (cliGlobalOpts cli) @?= ThemeLight
          goDebug (cliGlobalOpts cli) @?= True

  , testCase "parse AWS options" $ do
      case parseCli ["--region", "eu-west-1", "--profile", "myprofile", "list-stacks"] of
        Left e -> assertFailure e
        Right cli -> do
          aoRegion (cliAwsOpts cli) @?= Just "eu-west-1"
          aoProfile (cliAwsOpts cli) @?= Just "myprofile"

  , testCase "parse explain with codes" $ do
      case parseCli ["explain", "ERR_2001", "ERR_3001"] of
        Left e -> assertFailure e
        Right cli -> case cliCommand cli of
          CmdExplain codes -> codes @?= ["ERR_2001", "ERR_3001"]
          _ -> assertFailure "Expected CmdExplain"

  , testCase "invalid command fails" $ do
      case parseCli ["nonexistent-command"] of
        Left _  -> pure ()
        Right _ -> assertFailure "Expected parse failure for invalid command"

  , testCase "missing required arg fails" $ do
      case parseCli ["describe-stack"] of
        Left _  -> pure ()
        Right _ -> assertFailure "Expected parse failure for missing stackname"
  ]
