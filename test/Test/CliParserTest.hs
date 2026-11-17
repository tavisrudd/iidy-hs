module Test.CliParserTest (cliParserTests) where

import Data.List (isInfixOf)
import Data.Maybe (isJust)
import Options.Applicative (ParserResult (..), execParserPure, prefs, renderFailure, showHelpOnEmpty)
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Data.Text (Text)
import Iidy.Cli (AwsOpts (..), Cli (..), Commands (..), DeleteArgs (..), DescribeArgs (..), GetImportArgs (..), GetImportFormat (..), GlobalOpts (..), RenderArgs (..), RenderFormat (..), importPolicyFromOpts)
import Iidy.Cli.Parser (cliParserInfo)
import Iidy.Types (ColorChoice (..), Theme (..), YamlSpec (..))
import Iidy.Yaml.Imports.Types (ImportPolicy (..), isTrustedBase, trustedSourceText)

-- | Helper to parse CLI args using optparse-applicative in pure mode
parseCli :: [String] -> Either String Cli
parseCli args = case execParserPure (prefs showHelpOnEmpty) cliParserInfo args of
    Success cli -> Right cli
    Failure _ -> Left "parse failure"
    _other -> Left "unexpected result"

cliParserTests :: [TestTree]
cliParserTests =
    [ testCase "parse describe-stack" $ do
        case parseCli ["describe-stack", "my-stack"] of
            Left e -> assertFailure e
            Right cli -> case cliCommand cli of
                CmdDescribeStack args -> do
                    daStackname args @?= "my-stack"
                    daEvents args @?= 50
                _otherCmd -> assertFailure "Expected CmdDescribeStack"
    , testCase "parse describe-stack with events" $ do
        case parseCli ["describe-stack", "my-stack", "--events", "25"] of
            Left e -> assertFailure e
            Right cli -> case cliCommand cli of
                CmdDescribeStack args -> do
                    daStackname args @?= "my-stack"
                    daEvents args @?= 25
                _otherCmd -> assertFailure "Expected CmdDescribeStack"
    , testCase "parse render with defaults" $ do
        case parseCli ["render", "template.yaml"] of
            Left e -> assertFailure e
            Right cli -> case cliCommand cli of
                CmdRender args -> do
                    raTemplate args @?= "template.yaml"
                    raOutfile args @?= "stdout"
                    raFormat args @?= RenderYaml
                    raOverwrite args @?= False
                    raYamlSpec args @?= YamlAuto
                _otherCmd -> assertFailure "Expected CmdRender"
    , testCase "parse render with options" $ do
        case parseCli ["render", "t.yaml", "--format", "json", "--overwrite", "--yaml-spec", "1.1"] of
            Left e -> assertFailure e
            Right cli -> case cliCommand cli of
                CmdRender args -> do
                    raFormat args @?= RenderJson
                    raOverwrite args @?= True
                    raYamlSpec args @?= YamlV11
                _otherCmd -> assertFailure "Expected CmdRender"
    , testCase "parse delete-stack with --yes" $ do
        case parseCli ["delete-stack", "doomed-stack", "--yes"] of
            Left e -> assertFailure e
            Right cli -> case cliCommand cli of
                CmdDeleteStack args -> do
                    delStackname args @?= "doomed-stack"
                    delYes args @?= True
                    delFailIfAbsent args @?= False
                _otherCmd -> assertFailure "Expected CmdDeleteStack"
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
                _otherCmd -> assertFailure "Expected CmdExplain"
    , testCase "invalid command fails" $ do
        case parseCli ["nonexistent-command"] of
            Left _ -> pure ()
            Right _ -> assertFailure "Expected parse failure for invalid command"
    , testCase "missing required arg fails" $ do
        case parseCli ["describe-stack"] of
            Left _ -> pure ()
            Right _ -> assertFailure "Expected parse failure for missing stackname"
    , -- OutputFormat (RenderFormat) parsing tests
      testCase "render --format yaml" $ do
        case parseCli ["render", "t.yaml", "--format", "yaml"] of
            Left e -> assertFailure e
            Right cli -> case cliCommand cli of
                CmdRender args -> raFormat args @?= RenderYaml
                _otherCmd -> assertFailure "Expected CmdRender"
    , testCase "render --format yml" $ do
        case parseCli ["render", "t.yaml", "--format", "yml"] of
            Left e -> assertFailure e
            Right cli -> case cliCommand cli of
                CmdRender args -> raFormat args @?= RenderYaml
                _otherCmd -> assertFailure "Expected CmdRender"
    , testCase "render --format yaml-cloudformation" $ do
        case parseCli ["render", "t.yaml", "--format", "yaml-cloudformation"] of
            Left e -> assertFailure e
            Right cli -> case cliCommand cli of
                CmdRender args -> raFormat args @?= RenderCfnYaml
                _otherCmd -> assertFailure "Expected CmdRender"
    , testCase "render --format josn (typo) is rejected" $ do
        case parseCli ["render", "t.yaml", "--format", "josn"] of
            Left _ -> pure ()
            Right _ -> assertFailure "Expected parse failure for typo 'josn'"
    , testCase "render --format '' (empty) is rejected" $ do
        case parseCli ["render", "t.yaml", "--format", ""] of
            Left _ -> pure ()
            Right _ -> assertFailure "Expected parse failure for empty format"
    , testCase "get-import --format json" $ do
        case parseCli ["get-import", "some-import", "--format", "json"] of
            Left e -> assertFailure e
            Right cli -> case cliCommand cli of
                CmdGetImport args -> giaFormat args @?= GetImportJson
                _otherCmd -> assertFailure "Expected CmdGetImport"
    , testCase "get-import --format yaml (default)" $ do
        case parseCli ["get-import", "some-import"] of
            Left e -> assertFailure e
            Right cli -> case cliCommand cli of
                CmdGetImport args -> giaFormat args @?= GetImportYaml
                _otherCmd -> assertFailure "Expected CmdGetImport"
    , testCase "get-import --format yaml-cloudformation is rejected" $ do
        case parseCli ["get-import", "some-import", "--format", "yaml-cloudformation"] of
            Left _ -> pure ()
            Right _ -> assertFailure "Expected parse failure for yaml-cloudformation in get-import"
    , testCase "get-import --format bogus is a usage error naming the valid formats, exit 1" $
        case rejection ["get-import", "some-import", "--format", "bogus"] of
            Nothing -> assertFailure "Expected parse failure for bogus"
            Just (msg, code) -> do
                code @?= ExitFailure 1
                assertBool msg ("Unknown output format: bogus. Valid formats: json, yaml" `isInfixOf` msg)
    , testCase "get-import --format yaml-cloudformation is a usage error, exit 1" $
        fmap snd (rejection ["get-import", "some-import", "--format", "yaml-cloudformation"])
            @?= Just (ExitFailure 1)
    , testCase "get-import --format accepts exactly lower-case yaml and json" $
        mapM_
            (\f -> assertBool f (isJust (rejection ["get-import", "some-import", "--format", f])))
            ["yml", "YAML", "Json", "JSON", "Yaml"]
    , testCase "--trust-import-source is absent by default" $ do
        case parseCli ["render", "t.yaml"] of
            Left e -> assertFailure e
            Right cli -> trustedPrefixes cli @?= []
    , testCase "repeated --trust-import-source flags accumulate into the policy" $ do
        let args = ["--trust-import-source", "s3://bucket/", "--trust-import-source=https://t.example.com/x/", "render", "t.yaml"]
        case parseCli args of
            Left e -> assertFailure e
            Right cli -> do
                trustedPrefixes cli @?= ["s3://bucket/", "https://t.example.com/x/"]
                let policy = importPolicyFromOpts (cliGlobalOpts cli)
                isTrustedBase (ipTrustedSources policy) "s3://bucket/t.yaml" @?= True
                isTrustedBase (ipTrustedSources policy) "https://t.example.com/y/t.yaml" @?= False
    , testCase "an invalid --trust-import-source prefix is a parse error" $
        mapM_
            ( \p -> case parseCli ["--trust-import-source", p, "render", "t.yaml"] of
                Left _ -> pure ()
                Right _ -> assertFailure ("Expected parse failure for prefix " <> p)
            )
            ["s3://bucket", "ftp://host/", "templates/", "https:///"]
    ]
  where
    rejection :: [String] -> Maybe (String, ExitCode)
    rejection args = case execParserPure (prefs showHelpOnEmpty) cliParserInfo args of
        Failure f -> let (msg, code) = renderFailure f "iidy" in Just (msg, code)
        _other -> Nothing
    trustedPrefixes :: Cli -> [Text]
    trustedPrefixes = map trustedSourceText . goTrustedSources . cliGlobalOpts
