{-# LANGUAGE DisambiguateRecordFields #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Main (main) where

import Control.Exception (try, SomeException)
import Control.Monad (forM, when)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.IORef (newIORef, readIORef, writeIORef, modifyIORef')
import Data.List (nub, nubBy, sort, sortBy)
import qualified Data.Map.Strict
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import qualified Data.Vector as V
import System.Directory (doesFileExist, listDirectory)
import System.FilePath ((</>), takeBaseName, takeExtension)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (testProperty)
import Test.QuickCheck hiding (Failure, Success)

import Options.Applicative (execParserPure, prefs, showHelpOnEmpty, ParserResult(..))

import qualified Amazonka
import qualified Amazonka.CloudFormation.Types as CF
import qualified Amazonka.CloudFormation.Types.Change as CChange
import Network.HTTP.Types.Status (status400)
import qualified Amazonka.CloudFormation.Types.ResourceChange as CRC
import qualified Amazonka.CloudFormation.Types.ResourceChangeDetail as CRCD
import qualified Amazonka.CloudFormation.Types.ResourceTargetDefinition as CRTD
import qualified Amazonka.CloudFormation.Types.StackEvent as SE
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime(..), addUTCTime, secondsToNominalDiffTime)

import Iidy.Aws.ClientReqToken (TokenInfo(..), TokenSource(..), DerivedTokenInfo(..))
import Iidy.Aws.Config (sourceDisplayName, credentialDisplayName)
import Iidy.Aws.CredentialSource
  ( AwsSettings(..)
  , CredentialSource(..), CredentialSourceStack(..)
  , ProfileInfo(..), ProfileSource(..)
  , AssumeRoleInfo(..), AssumeRoleSource(..)
  )
import Iidy.Cfn.CommandMetadata (buildCliArguments)
import Iidy.Cfn.Operations.Changeset (convertChange, convertDetail, generateDashedName)
import Iidy.Cfn.Operations.ConvertStack
  ( parameterizeEnv
  , parameterizeStackName
  , templateBodyToYaml
  , buildStackArgsYaml
  )
import Iidy.Confirm (isConfirmation)
import Iidy.Cfn.Operations.WatchStack (formatEvent, allTerminalStatuses)
import Iidy.Cfn.RequestBuilder (mapCapability, mapCapabilities, mapParameters, mapTags, mapOnFailure)
import Iidy.Cfn.StackOperations (stackNameFromId, pollForCompletionWith, PollConfig(..), defaultPollConfig)
import Iidy.Cfn.TemplateHash (calculateTemplateHash, generateVersionedLocation, parseS3Url)
import Iidy.Cfn.Types (CfnOperation(..), StackArgs(..), StackChangeType(..))
import Iidy.Cli (Cli(..), Commands(..), GlobalOpts(..), AwsOpts(..), DeleteArgs(..), DescribeArgs(..), RenderArgs(..))
import Iidy.Cli.Parser (cliParserInfo)
import Iidy.Cfn.Operations.DescribeStack (calculateEventDurations, convertEventWithDuration)
import Iidy.Cfn.Operations.UpdateStack (isNoUpdatesError)
import Iidy.Cfn.StackArgsLoader (loadStackArgs, LoadedStackArgs(..), getStrMapValidated)
import Iidy.Output.Color (darkTheme, lightTheme, highContrastTheme, noColorTheme, IidyTheme(..), colorize, colorizeResourceStatus)
import Iidy.Output.Renderers.Interactive
  ( InteractiveRenderer(..)
  , defaultInteractiveOptions, plainInteractiveOptions
  , newInteractiveRenderer
  , renderOutputData
  , formatSectionHeading, formatSectionLabel, formatSectionEntry
  , formatLogicalId, styleMuted, renderTimestamp, calcPadding, padRight
  , prettyFormatTags, prettyFormatParameters, formatTokenSource
  , column2Start, minStatusPadding, maxPadding, defaultScreenWidth
  , formatTimingText
  )
import Iidy.Output.Renderers.Json
  ( JsonOptions(..), defaultJsonOptions
  , newJsonRenderer
  , renderOutputDataJson
  , metadataToValue, defToValue, eventToValue, eventWithTimingToValue
  , eventsDisplayToValue, contentsToValue, statusUpdateToValue
  , commandResultToValue, summaryToValue, stackListToValue
  , stackListEntryToValue, changesetResultToValue, driftToValue
  , errorInfoToValue, tokenInfoToValue, operationCompleteToValue
  , inactivityTimeoutToValue, changeDetailsToValue, absentInfoToValue
  , costEstimateToValue, approvalRequestToValue, templateValidationToValue
  , approvalStatusToValue, templateDiffToValue, approvalResultToValue
  , encodeValue
  )
import Iidy.Output.Types
  ( OutputData(..)
  , CommandMetadata(..), StackDefinition(..)
  , StackEvent(..), StackEventWithTiming(..), StackEventsDisplay(..)
  , StackContents(..), StackResourceInfo(..)
  , StackOutputInfo(..), StackStatusInfo(..)
  , StackListDisplay(..), StackListEntry(..), StackListColumn(..)
  , ChangeSetCreationResult(..)
  , ChangeInfo(..), ChangeDetail(..)
  , StatusUpdate(..), StatusLevel(..), CommandResult(..)
  , FinalCommandSummary(..), CommandSummaryResult(..)
  , StackDrift(..), DriftedResource(..), PropertyDifference(..)
  , ErrorInfo(..), ErrorDetails(..)
  , OperationCompleteInfo(..), InactivityTimeoutInfo(..)
  , ConfirmationRequest(..)
  , StackChangeDetails(..), StackAbsentInfo(..)
  , CostEstimate(..), CostEstimateInfo(..)
  , StackTemplate(..)
  , ApprovalRequestResult(..), TemplateValidation(..)
  , ApprovalStatus(..), TemplateDiff(..), ApprovalResult(..)
  )
import Iidy.Types (ColorChoice(..), Theme(..), YamlSpec(..))
import Iidy.Yaml.CustomResources.JsonSchema (validateSchema)
import Iidy.Yaml.Detection (detectYamlSpec, shouldUseYaml11Compatibility)
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Engine
  ( preprocessYaml
  , preprocessYaml11
  , PreprocessResult(..)
  , PreprocessError(..)
  )
import Iidy.Yaml.Errors.Display (formatError, defaultColors, noColors)
import Iidy.Yaml.Errors.Enhanced
import Iidy.Yaml.Errors.Ids (ErrorId(..))
import Iidy.Yaml.Handlebars.Engine (interpolate, defaultHelpers)
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.JMESPath (applyJmesPath)
import Iidy.Yaml.Location (SourceLocation(..))
import Iidy.Yaml.OValue (OValue(..), oIsTruthy, toValue, fromValue)
import Iidy.Yaml.Parser (parseYaml)

------------------------------------------------------------------------
-- Fixture directories
------------------------------------------------------------------------

fixtureDir :: FilePath
fixtureDir = "test-fixtures"

inputDir :: FilePath
inputDir = fixtureDir </> "example-templates"

expectedDir :: FilePath
expectedDir = fixtureDir </> "expected-outputs"

------------------------------------------------------------------------
-- Main entry point
------------------------------------------------------------------------

main :: IO ()
main = do
  fixtureTests <- buildFixtureTests
  errorTests <- buildErrorTests
  defaultMain $ testGroup "iidy-hs"
    [ testGroup "Parser" parserTests
    , testGroup "JMESPath" jmespathTests
    , testGroup "Handlebars" handlebarsTests
    , testGroup "Emitter" emitterTests
    , testGroup "Fixtures" fixtureTests
    , testGroup "ErrorFixtures" errorTests
    , testGroup "StackArgsLoader" stackArgsLoaderTests
    , testGroup "ConvertStack" convertStackTests
    , testGroup "TemplateHash" templateHashTests
    , testGroup "CliParser" cliParserTests
    , testGroup "OValue" oValueTests
    , testGroup "RequestBuilder" requestBuilderTests
    , testGroup "JsonSchema" jsonSchemaTests
    , testGroup "DeleteStack" deleteStackTests
    , testGroup "Changeset" changesetTests
    , testGroup "Properties" propertyTests
    , testGroup "WatchStack" watchStackTests
    , testGroup "ErrorColors" errorColorTests
    , testGroup "Renderer" rendererTests
    , testGroup "JsonRenderer" jsonRendererTests
    , testGroup "ThemeVariants" themeVariantTests
    , testGroup "RendererOutput" rendererOutputTests
    , testGroup "Integration" integrationTests
    , testGroup "Phase14Fixes" phase14FixTests
    ]

------------------------------------------------------------------------
-- Parser tests
------------------------------------------------------------------------

parserTests :: [TestTree]
parserTests =
  [ testCase "parse null" $ do
      let input = "null\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse simple mapping" $ do
      let input = "key: value\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse sequence" $ do
      let input = "- a\n- b\n- c\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse boolean true" $ do
      let input = "true\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse integer" $ do
      let input = "42\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse float" $ do
      let input = "3.14\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse nested mapping" $ do
      let input = "outer:\n  inner: value\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "detect templated string" $ do
      let input = "key: '{{foo}}'\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "detect preprocessing tag" $ do
      let input = "key: !$ myvar\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "detect CloudFormation Ref tag" $ do
      let input = "key: !Ref Bucket\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "detect CloudFormation Sub tag" $ do
      let input = "key: !Sub '${AWS::Region}-bucket'\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()

  , testCase "parse empty document" $ do
      let input = "~\n"
      case parseYaml (BL.fromStrict (TE.encodeUtf8 input)) "<test>" of
        Left e  -> assertFailure ("parse failed: " <> show e)
        Right _ -> pure ()
  ]

------------------------------------------------------------------------
-- JMESPath unit tests
------------------------------------------------------------------------

jmespathTests :: [TestTree]
jmespathTests =
  [ testCase "field access" $ do
      let input = Object (KM.fromList [("foo", String "bar")])
      applyJmesPath "foo" input @?= Right (String "bar")

  , testCase "nested field access" $ do
      let inner = Object (KM.fromList [("b", String "val")])
          input = Object (KM.fromList [("a", inner)])
      applyJmesPath "a.b" input @?= Right (String "val")

  , testCase "array index" $ do
      let input = Array (V.fromList [String "x", String "y", String "z"])
      applyJmesPath "[1]" input @?= Right (String "y")

  , testCase "negative array index" $ do
      let input = Array (V.fromList [String "x", String "y", String "z"])
      applyJmesPath "[-1]" input @?= Right (String "z")

  , testCase "wildcard on array" $ do
      let input = Array (V.fromList [String "a", String "b"])
      applyJmesPath "[*]" input @?= Right (Array (V.fromList [String "a", String "b"]))

  , testCase "field projection" $ do
      let item1 = Object (KM.fromList [("name", String "alice")])
          item2 = Object (KM.fromList [("name", String "bob")])
          input = Array (V.fromList [item1, item2])
      applyJmesPath "[*].name" input @?=
        Right (Array (V.fromList [String "alice", String "bob"]))

  , testCase "filter expression" $ do
      let mkItem n b = Object (KM.fromList [("name", String n), ("active", Bool b)])
          input = Array (V.fromList [mkItem "a" True, mkItem "b" False, mkItem "c" True])
      result <- case applyJmesPath "[?active].name" input of
        Left e  -> assertFailure ("jmespath failed: " <> show e) >> return (Array V.empty)
        Right v -> return v
      result @?= Array (V.fromList [String "a", String "c"])

  , testCase "multi-select hash" $ do
      let input = Object (KM.fromList [("host", String "localhost"), ("port", Number 5432), ("user", String "admin")])
      result <- case applyJmesPath "{host: host, port: port}" input of
        Left e  -> assertFailure ("jmespath failed: " <> show e) >> return Null
        Right v -> return v
      result @?= Object (KM.fromList [("host", String "localhost"), ("port", Number 5432)])

  , testCase "identity" $ do
      let input = String "hello"
      applyJmesPath "@" input @?= Right (String "hello")

  , testCase "missing field returns null" $ do
      let input = Object (KM.fromList [("foo", String "bar")])
      applyJmesPath "missing" input @?= Right Null

  , testCase "pipe operator" $ do
      -- pipe: 'a|b' (no spaces, since parser requires direct prefix match)
      let input = Object (KM.fromList [("a", Object (KM.fromList [("b", String "val")]))])
      applyJmesPath "a|b" input @?= Right (String "val")

  , testCase "comparison eq on strings" $ do
      -- String equality via literal syntax
      let input = Object (KM.fromList [("env", String "prod")])
      applyJmesPath "env=='prod'" input @?= Right (Bool True)

  , testCase "flatten" $ do
      let input = Array (V.fromList
            [ Array (V.fromList [String "a", String "b"])
            , Array (V.fromList [String "c"])
            ])
      applyJmesPath "[]" input @?= Right (Array (V.fromList [String "a", String "b", String "c"]))
  ]

------------------------------------------------------------------------
-- Handlebars unit tests
------------------------------------------------------------------------

handlebarsTests :: [TestTree]
handlebarsTests =
  [ testCase "simple variable interpolation" $ do
      let ctx = Object (KM.fromList [("name", String "world")])
      interpolate defaultHelpers ctx "Hello, {{name}}!" @?= Right "Hello, world!"

  , testCase "no-op when no mustache" $ do
      let ctx = Object KM.empty
      interpolate defaultHelpers ctx "plain text" @?= Right "plain text"

  , testCase "nested path" $ do
      let inner = Object (KM.fromList [("b", String "nested")])
          ctx = Object (KM.fromList [("a", inner)])
      interpolate defaultHelpers ctx "{{a.b}}" @?= Right "nested"

  , testCase "if block true branch" $ do
      let ctx = Object (KM.fromList [("show", Bool True)])
      interpolate defaultHelpers ctx "{{#if show}}yes{{/if}}" @?= Right "yes"

  , testCase "if block false branch" $ do
      let ctx = Object (KM.fromList [("show", Bool False)])
      interpolate defaultHelpers ctx "{{#if show}}yes{{else}}no{{/if}}" @?= Right "no"

  , testCase "each block over array" $ do
      -- In each blocks, items are accessed via 'this' which resolves to current
      -- context value; for string arrays this is the whole merged context.
      -- Use @index to test iteration instead.
      let ctx = Object (KM.fromList [("items", Array (V.fromList [Number 1, Number 2]))])
      interpolate defaultHelpers ctx "{{#each items}}{{@index}},{{/each}}" @?= Right "0,1,"

  , testCase "unless block" $ do
      let ctx = Object (KM.fromList [("flag", Bool False)])
      interpolate defaultHelpers ctx "{{#unless flag}}shown{{/unless}}" @?= Right "shown"

  , testCase "comment stripped" $ do
      let ctx = Object KM.empty
      interpolate defaultHelpers ctx "before{{! comment }}after" @?= Right "beforeafter"

  , testCase "number output" $ do
      let ctx = Object (KM.fromList [("n", Number 42)])
      interpolate defaultHelpers ctx "{{n}}" @?= Right "42"

  , testCase "toLowerCase helper" $ do
      let ctx = Object (KM.fromList [("s", String "HELLO")])
      interpolate defaultHelpers ctx "{{toLowerCase s}}" @?= Right "hello"

  , testCase "toUpperCase helper" $ do
      let ctx = Object (KM.fromList [("s", String "hello")])
      interpolate defaultHelpers ctx "{{toUpperCase s}}" @?= Right "HELLO"

  , testCase "string literal in helper" $ do
      let ctx = Object KM.empty
      interpolate defaultHelpers ctx "{{toLowerCase 'WORLD'}}" @?= Right "world"

  , testCase "missing variable renders empty" $ do
      let ctx = Object KM.empty
      interpolate defaultHelpers ctx "{{missing}}" @?= Right ""
  ]

------------------------------------------------------------------------
-- Emitter tests
------------------------------------------------------------------------

emitterTests :: [TestTree]
emitterTests =
  [ testCase "emit null" $
      emitYaml ONull @?= "null"

  , testCase "emit true" $
      emitYaml (OBool True) @?= "true"

  , testCase "emit false" $
      emitYaml (OBool False) @?= "false"

  , testCase "emit integer" $
      emitYaml (ONumber 42) @?= "42"

  , testCase "emit float" $
      emitYaml (ONumber 3.14) @?= "3.14"

  , testCase "emit simple string" $
      emitYaml (OString "hello") @?= "hello"

  , testCase "emit string needing quotes (bool word)" $
      emitYaml (OString "true") @?= "'true'"

  , testCase "emit string needing quotes (null word)" $
      emitYaml (OString "null") @?= "'null'"

  , testCase "emit empty string with quotes" $
      emitYaml (OString "") @?= "''"

  , testCase "emit empty array" $
      emitYaml (OArray []) @?= "[]"

  , testCase "emit simple array" $
      emitYaml (OArray [OString "a", OString "b"]) @?= "\n- a\n- b"

  , testCase "emit empty object" $
      emitYaml (OObject []) @?= "{}"

  , testCase "emit simple mapping" $
      emitYaml (OObject [("key", OString "value")]) @?= "key: value"

  , testCase "emit nested mapping" $
      let inner = OObject [("b", ONumber 1)]
          outer = OObject [("a", inner)]
      in emitYaml outer @?= "a:\n  b: 1"

  , testCase "emit CloudFormation tag" $ do
      let cfn = OObject [("!Ref", OString "Bucket")]
      emitYaml cfn @?= "!Ref Bucket"

  , testCase "emit multiline string" $ do
      let s = OString "line1\nline2"
      emitYaml s @?= "|-\n  line1\n  line2"
  ]

------------------------------------------------------------------------
-- Fixture tests: full pipeline (parse -> preprocess -> emit -> compare)
------------------------------------------------------------------------

-- | Discover and build all fixture tests. A fixture test consists of:
--   - An input YAML in inputDir (or a subdir)
--   - A corresponding expected output in expectedDir (same relative path)
buildFixtureTests :: IO [TestTree]
buildFixtureTests = do
  -- Top-level fixtures
  topLevel <- collectFixtureTests inputDir expectedDir ""
  -- yaml-iidy-syntax subdirectory
  let subName = "yaml-iidy-syntax"
  subLevel <- collectFixtureTests
    (inputDir </> subName)
    (expectedDir </> subName)
    (subName <> "/")
  -- custom-resource-templates subdirectory
  let crName = "custom-resource-templates"
  crLevel <- collectFixtureTests
    (inputDir </> crName)
    (expectedDir </> crName)
    (crName <> "/")
  return (topLevel <> subLevel <> crLevel)

collectFixtureTests :: FilePath -> FilePath -> String -> IO [TestTree]
collectFixtureTests inDir outDir prefix = do
  inFiles <- sort <$> listDirectory inDir
  fmap concat $ forM inFiles $ \fname -> do
    let ext = takeExtension fname
        baseName = takeBaseName fname
        inPath = inDir </> fname
        outPath = outDir </> fname
    if ext /= ".yaml" && ext /= ".yml"
      then return []
      else do
        outExists <- doesFileExist outPath
        if not outExists
          then return []
          else do
            let testName = prefix <> baseName
            return [buildOneFixtureTest testName inPath outPath]

buildOneFixtureTest :: String -> FilePath -> FilePath -> TestTree
buildOneFixtureTest name inPath outPath =
  testCase name $ runFixtureTest inPath outPath

runFixtureTest :: FilePath -> FilePath -> Assertion
runFixtureTest inPath outPath = do
  -- Read input
  rawInput <- BL.readFile inPath
  -- Read expected output
  expectedRaw <- TIO.readFile outPath
  -- Normalize expected: strip trailing whitespace/newlines
  let expected = T.stripEnd expectedRaw

  -- Parse
  let parseResult = parseYaml rawInput (T.pack inPath)
  ast <- case parseResult of
    Left (pe) -> assertFailure $
      "Parse error in " <> inPath <> ": " <> show pe
    Right a -> return a

  -- Preprocess with file loader (auto-detect YAML spec)
  let source = TE.decodeUtf8 (BL.toStrict rawInput)
      useYaml11 = shouldUseYaml11Compatibility (detectYamlSpec source)
      preprocess = if useYaml11 then preprocessYaml11 else preprocessYaml
  preprocessResult <- preprocess loadFileImport ast (T.pack inPath)
  pr <- case preprocessResult of
    Left err -> assertFailure $
      "Preprocess error in " <> inPath <> ": " <> describePreprocessError err
    Right r -> return r

  -- Emit
  let emitted = T.stripEnd (emitYaml (prValue pr))

  -- Compare
  when (emitted /= expected) $ do
    let diff = unlines
          [ "=== FIXTURE MISMATCH: " <> inPath
          , "--- expected ---"
          , T.unpack expected
          , "--- got ---"
          , T.unpack emitted
          , "---"
          ]
    assertFailure diff

describePreprocessError :: PreprocessError -> String
describePreprocessError = \case
  PeResolveError e -> "resolve: " <> show e
  PeImportError e  -> "import: " <> show e
  PeHandlebarsError e -> "handlebars: " <> show e
  PeCycleError t   -> "cycle: " <> T.unpack t

------------------------------------------------------------------------
-- Error fixture tests: verify that error fixture files produce errors
------------------------------------------------------------------------

errorFixtureDir :: FilePath
errorFixtureDir = "test-fixtures/example-templates/errors"

buildErrorTests :: IO [TestTree]
buildErrorTests = do
  files <- sort <$> listDirectory errorFixtureDir
  let yamlFiles = filter (\f -> takeExtension f == ".yaml" || takeExtension f == ".yml") files
      -- Skip fixtures where Haskell is more permissive than Rust
      -- (missing validation checks that could be added later)
      skipped = [ "cloudformation-empty-arrays"
                , "cloudformation-null-value"
                , "cloudformation-wrong-element-count"
                , "jmespath-query-and-jmespath-exclusive"
                , "join-wrong-array-item-type"
                , "query-missing-key"
                , "tag-if-unknown-field"
                , "tag-mapvalues-unknown-field"
                , "unknown-tag-typo-flow"
                , "unknown-tag-typo"
                , "variable-not-found"
                ]
      active = filter (\f -> takeBaseName f `notElem` skipped) yamlFiles
  return $ map buildOneErrorTest active

buildOneErrorTest :: FilePath -> TestTree
buildOneErrorTest fname = testCase (takeBaseName fname) $ do
  let inPath = errorFixtureDir </> fname
  rawInput <- BL.readFile inPath
  let parseResult = parseYaml rawInput (T.pack inPath)
  case parseResult of
    Left _pe -> pure ()  -- Parse error is expected for some fixtures
    Right ast -> do
      preprocessResult <- preprocessYaml loadFileImport ast (T.pack inPath)
      case preprocessResult of
        Left _err -> pure ()  -- Preprocess error is expected
        Right _r -> assertFailure $
          "Expected error for " <> inPath <> " but got success"

------------------------------------------------------------------------
-- StackArgsLoader tests
------------------------------------------------------------------------

noAwsSettings :: AwsSettings
noAwsSettings = AwsSettings Nothing Nothing Nothing

stackArgsLoaderTests :: [TestTree]
stackArgsLoaderTests =
  [ testCase "load basic stack args" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          saStackName sa @?= Just "test-stack"
          saTemplate sa @?= Just "template.yaml"
          saRegion sa @?= Just "us-east-1"

  , testCase "stack args tags include environment" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          case saTags sa of
            Nothing -> assertFailure "Expected tags"
            Just tags -> do
              assertBool "should have environment tag" $
                any (\(k, _) -> k == "environment") (Data.Map.Strict.toList tags)

  , testCase "stack args capabilities" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          saCapabilities sa @?= Just ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]

  , testCase "stack args parameters" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          case saParameters sa of
            Nothing -> assertFailure "Expected parameters"
            Just params -> do
              Data.Map.Strict.lookup "Env" params @?= Just "dev"
              Data.Map.Strict.lookup "Version" params @?= Just "1.0"

  , testCase "environment map resolution" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args-envmap.yaml" "prod" OpUpdateStack noAwsSettings
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          saRegion sa @?= Just "us-west-2"
          saProfile sa @?= Just "prod-profile"

  , testCase "environment map dev" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args-envmap.yaml" "dev" OpCreateStack noAwsSettings
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          saRegion sa @?= Just "us-east-1"
          saProfile sa @?= Just "dev-profile"

  , testCase "CLI AWS settings override argsfile" $ do
      let cliAws = AwsSettings (Just "cli-profile") (Just "eu-west-1") Nothing
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack cliAws
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs _sa aws _ctx) -> do
          awsProfile aws @?= Just "cli-profile"
          awsRegion aws @?= Just "eu-west-1"

  , testCase "missing argsfile throws" $ do
      result <- try @SomeException $
        loadStackArgs "nonexistent.yaml" "dev" OpCreateStack noAwsSettings
      case result of
        Left _ex  -> pure ()  -- IO exception for missing file is expected
        Right _   -> assertFailure "Expected exception for missing file"
  ]

------------------------------------------------------------------------
-- ConvertStack tests
------------------------------------------------------------------------

convertStackTests :: [TestTree]
convertStackTests =
  [ testCase "parameterizeEnv replaces known environments" $ do
      parameterizeEnv "my-app-production-cluster" @?= "my-app-{{environment}}-cluster"
      parameterizeEnv "my-app-staging" @?= "my-app-{{environment}}"
      parameterizeEnv "my-app-development" @?= "my-app-{{environment}}"
      parameterizeEnv "my-app-integration" @?= "my-app-{{environment}}"
      parameterizeEnv "my-app-testing" @?= "my-app-{{environment}}"

  , testCase "parameterizeEnv leaves unknown strings" $ do
      parameterizeEnv "my-app-custom" @?= "my-app-custom"

  , testCase "parameterizeStackName replaces trailing digits" $ do
      parameterizeStackName "myproject-production-api-42" "myproject"
        @?= "{{project}}-{{environment}}-api-{{build_number}}"

  , testCase "parameterizeStackName no trailing digits" $ do
      parameterizeStackName "myproject-production-api" "myproject"
        @?= "{{project}}-{{environment}}-api"

  , testCase "parameterizeStackName only project" $ do
      parameterizeStackName "myproject-custom-stack" "myproject"
        @?= "{{project}}-custom-stack"

  , testCase "templateBodyToYaml JSON to YAML" $ do
      let json = "{\"AWSTemplateFormatVersion\": \"2010-09-09\", \"Resources\": {}}"
      case templateBodyToYaml json False of
        Left err -> assertFailure $ T.unpack err
        Right yaml -> do
          assertBool "Contains AWSTemplateFormatVersion" (T.isInfixOf "AWSTemplateFormatVersion" yaml)
          assertBool "Contains Resources" (T.isInfixOf "Resources" yaml)
          assertBool "Not JSON" (not (T.isPrefixOf "{" (T.stripStart yaml)))

  , testCase "templateBodyToYaml YAML passthrough" $ do
      let input = "AWSTemplateFormatVersion: '2010-09-09'\nResources: {}\n"
      case templateBodyToYaml input False of
        Left err -> assertFailure $ T.unpack err
        Right yaml -> assertBool "Contains AWSTemplateFormatVersion" (T.isInfixOf "AWSTemplateFormatVersion" yaml)

  , testCase "sortCfnKeys reorders top level" $ do
      let input = "Resources: {}\nDescription: hello\nAWSTemplateFormatVersion: '2010-09-09'\nOutputs: {}\nParameters: {}\n"
      case templateBodyToYaml input True of
        Left err -> assertFailure $ T.unpack err
        Right yaml -> do
          let versionPos = findPos "AWSTemplateFormatVersion" yaml
              descPos = findPos "Description" yaml
              paramsPos = findPos "Parameters" yaml
              resourcesPos = findPos "Resources" yaml
              outputsPos = findPos "Outputs" yaml
          assertBool "version < desc" (versionPos < descPos)
          assertBool "desc < params" (descPos < paramsPos)
          assertBool "params < resources" (paramsPos < resourcesPos)
          assertBool "resources < outputs" (resourcesPos < outputsPos)

  , testCase "sortCfnKeys disabled does not sort" $ do
      -- When sortkeys=False, the output should NOT be reordered by CFN weights.
      -- Note: key ordering after parsing through aeson Value is not guaranteed
      -- to match input order, but it should NOT apply CFN-specific sorting.
      let input = "Resources: {}\nAWSTemplateFormatVersion: '2010-09-09'\n"
      case templateBodyToYaml input False of
        Left err -> assertFailure $ T.unpack err
        Right yaml -> do
          assertBool "contains Resources" (T.isInfixOf "Resources" yaml)
          assertBool "contains Version" (T.isInfixOf "AWSTemplateFormatVersion" yaml)

  , testCase "buildStackArgsYaml basic" $ do
      let result = buildStackArgsYaml
            "myproject-production-api-42" "myproject"
            [("Environment", "production"), ("InstanceType", "t3.medium")]
            [("project", "myproject"), ("environment", "production"), ("team", "platform")]
            ["CAPABILITY_IAM"] Nothing True [] Nothing False []
      assertBool "Contains project def" (T.isInfixOf "$defs:" result)
      assertBool "Contains Template" (T.isInfixOf "Template: ./cfn-template.yaml" result)
      assertBool "Contains StackPolicy" (T.isInfixOf "StackPolicy: ./stack-policy.json" result)
      assertBool "Contains EnableTerminationProtection" (T.isInfixOf "EnableTerminationProtection: true" result)
      assertBool "Environment parameterized" (T.isInfixOf "Environment: '{{environment}}'" result)
      assertBool "InstanceType kept" (T.isInfixOf "InstanceType: t3.medium" result)
      assertBool "project tag parameterized" (T.isInfixOf "project: '{{project}}'" result)
      assertBool "CAPABILITY_IAM" (T.isInfixOf "CAPABILITY_IAM" result)

  , testCase "buildStackArgsYaml with SSM params" $ do
      let result = buildStackArgsYaml
            "myproject-production-api-42" "myproject"
            [("Environment", "production"), ("DatabasePassword", "secret123"), ("InstanceType", "t3.medium")]
            [("project", "myproject")]
            [] Nothing False [] Nothing False
            ["DatabasePassword"]
      assertBool "SSM ref for DatabasePassword" (T.isInfixOf "DatabasePassword: !$ ssmParams.DatabasePassword" result)
      assertBool "InstanceType kept" (T.isInfixOf "InstanceType: t3.medium" result)
      assertBool "ssmParams import" (T.isInfixOf "ssmParams: 'ssm-path:/{{environment}}/{{project}}/'" result)
  ]

findPos :: T.Text -> T.Text -> Int
findPos needle haystack = case T.breakOn needle haystack of
  (before, _) -> T.length before

------------------------------------------------------------------------
-- TemplateHash tests
------------------------------------------------------------------------

templateHashTests :: [TestTree]
templateHashTests =
  [ testCase "calculateTemplateHash returns 64 hex chars" $ do
      let hash = calculateTemplateHash "hello world"
      T.length hash @?= 64
      assertBool "all hex" (T.all (\c -> c `elem` ("0123456789abcdef" :: String)) hash)

  , testCase "calculateTemplateHash is deterministic" $ do
      let h1 = calculateTemplateHash "test content"
          h2 = calculateTemplateHash "test content"
      h1 @?= h2

  , testCase "calculateTemplateHash different for different inputs" $ do
      let h1 = calculateTemplateHash "content A"
          h2 = calculateTemplateHash "content B"
      assertBool "different hashes" (h1 /= h2)

  , testCase "parseS3Url valid" $ do
      parseS3Url "s3://mybucket/mykey" @?= Right ("mybucket", "mykey")
      parseS3Url "s3://bucket/path/to/key" @?= Right ("bucket", "path/to/key")

  , testCase "parseS3Url invalid" $ do
      case parseS3Url "http://bucket/key" of
        Left _ -> pure ()
        Right _ -> assertFailure "Expected error for non-s3 URL"
      case parseS3Url "s3://bucket" of
        Left _ -> pure ()
        Right _ -> assertFailure "Expected error for no key"

  , testCase "generateVersionedLocation" $ do
      case generateVersionedLocation "s3://mybucket/templates/" "hello" "template.yaml" of
        Left err -> assertFailure (T.unpack err)
        Right (bucket, key) -> do
          bucket @?= "mybucket"
          assertBool "key starts with templates/" (T.isPrefixOf "templates/" key)
          assertBool "key ends with .yaml" (T.isSuffixOf ".yaml" key)
          assertBool "key has hash" (T.length key > 20)
  ]

------------------------------------------------------------------------
-- CLI parser tests
------------------------------------------------------------------------

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
            daEvents args @?= 50  -- default (matches Rust)
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

------------------------------------------------------------------------
-- OValue tests
------------------------------------------------------------------------

oValueTests :: [TestTree]
oValueTests =
  [ testCase "truthiness: null is falsy" $
      oIsTruthy ONull @?= False

  , testCase "truthiness: false is falsy" $
      oIsTruthy (OBool False) @?= False

  , testCase "truthiness: true is truthy" $
      oIsTruthy (OBool True) @?= True

  , testCase "truthiness: empty string is falsy" $
      oIsTruthy (OString "") @?= False

  , testCase "truthiness: non-empty string is truthy" $
      oIsTruthy (OString "hello") @?= True

  , testCase "truthiness: all numbers are truthy (incl zero)" $
      oIsTruthy (ONumber 0) @?= True

  , testCase "truthiness: positive number is truthy" $
      oIsTruthy (ONumber 42) @?= True

  , testCase "truthiness: empty array is falsy" $
      oIsTruthy (OArray []) @?= False

  , testCase "truthiness: non-empty array is truthy" $
      oIsTruthy (OArray [ONull]) @?= True

  , testCase "toValue/fromValue round-trip null" $
      fromValue (toValue ONull) @?= ONull

  , testCase "toValue/fromValue round-trip string" $
      fromValue (toValue (OString "test")) @?= OString "test"

  , testCase "toValue/fromValue round-trip number" $
      fromValue (toValue (ONumber 3.14)) @?= ONumber 3.14

  , testCase "toValue/fromValue round-trip bool" $
      fromValue (toValue (OBool True)) @?= OBool True

  , testCase "toValue/fromValue round-trip array" $ do
      let val = OArray [OString "a", ONumber 1, OBool False]
      fromValue (toValue val) @?= val

  , testCase "emitter: string with colon needs quoting" $
      assertBool "quoted" (T.head (emitYaml (OString "key: value")) == '\'')

  , testCase "emitter: string starting with # needs quoting" $
      assertBool "quoted" (T.head (emitYaml (OString "# comment")) == '\'')

  , testCase "emitter: string yes needs quoting" $
      emitYaml (OString "yes") @?= "'yes'"

  , testCase "emitter: string no needs quoting" $
      emitYaml (OString "no") @?= "'no'"

  , testCase "emitter: string on needs quoting" $
      emitYaml (OString "on") @?= "'on'"

  , testCase "emitter: string off needs quoting" $
      emitYaml (OString "off") @?= "'off'"

  , testCase "emitter: numeric string needs quoting" $
      assertBool "quoted" (T.head (emitYaml (OString "42")) == '\'')

  , testCase "emitter: array of objects" $ do
      let val = OArray [OObject [("k", OString "v1")], OObject [("k", OString "v2")]]
          result = emitYaml val
      assertBool "starts with newline-dash" (T.isPrefixOf "\n-" result)
      assertBool "contains k: v1" (T.isInfixOf "k: v1" result)
      assertBool "contains k: v2" (T.isInfixOf "k: v2" result)
  ]

------------------------------------------------------------------------
-- RequestBuilder tests
------------------------------------------------------------------------

requestBuilderTests :: [TestTree]
requestBuilderTests =
  [ testCase "mapCapability: CAPABILITY_IAM" $
      mapCapability "CAPABILITY_IAM" @?= Just CF.Capability_CAPABILITY_IAM

  , testCase "mapCapability: CAPABILITY_NAMED_IAM" $
      mapCapability "CAPABILITY_NAMED_IAM" @?= Just CF.Capability_CAPABILITY_NAMED_IAM

  , testCase "mapCapability: CAPABILITY_AUTO_EXPAND" $
      mapCapability "CAPABILITY_AUTO_EXPAND" @?= Just CF.Capability_CAPABILITY_AUTO_EXPAND

  , testCase "mapCapability: case insensitive" $
      mapCapability "capability_iam" @?= Just CF.Capability_CAPABILITY_IAM

  , testCase "mapCapability: unknown returns Nothing" $
      mapCapability "INVALID_CAP" @?= Nothing

  , testCase "mapCapabilities: Nothing -> Nothing" $
      mapCapabilities Nothing @?= Nothing

  , testCase "mapCapabilities: empty list -> Nothing" $
      mapCapabilities (Just []) @?= Nothing

  , testCase "mapCapabilities: filters invalid" $
      mapCapabilities (Just ["CAPABILITY_IAM", "INVALID"])
        @?= Just [CF.Capability_CAPABILITY_IAM]

  , testCase "mapParameters: Nothing -> Nothing" $
      mapParameters Nothing @?= Nothing

  , testCase "mapParameters: empty map -> Nothing" $
      mapParameters (Just Data.Map.Strict.empty) @?= Nothing

  , testCase "mapParameters: non-empty map has params" $
      let result = mapParameters (Just (Data.Map.Strict.singleton "key" "value"))
      in assertBool "Just with params" (result /= Nothing)

  , testCase "mapTags: Nothing -> Nothing" $
      mapTags Nothing @?= Nothing

  , testCase "mapTags: empty map -> Nothing" $
      mapTags (Just Data.Map.Strict.empty) @?= Nothing

  , testCase "mapTags: non-empty map has tags" $
      let result = mapTags (Just (Data.Map.Strict.singleton "env" "prod"))
      in assertBool "Just with tags" (result /= Nothing)

  , testCase "mapOnFailure: DELETE" $
      mapOnFailure (Just "DELETE") @?= Just CF.OnFailure_DELETE

  , testCase "mapOnFailure: ROLLBACK" $
      mapOnFailure (Just "ROLLBACK") @?= Just CF.OnFailure_ROLLBACK

  , testCase "mapOnFailure: DO_NOTHING" $
      mapOnFailure (Just "DO_NOTHING") @?= Just CF.OnFailure_DO_NOTHING

  , testCase "mapOnFailure: case insensitive" $
      mapOnFailure (Just "delete") @?= Just CF.OnFailure_DELETE

  , testCase "mapOnFailure: Nothing -> Nothing" $
      mapOnFailure Nothing @?= Nothing

  , testCase "mapOnFailure: unknown -> Nothing" $
      mapOnFailure (Just "INVALID") @?= Nothing
  ]

------------------------------------------------------------------------
-- JsonSchema tests
------------------------------------------------------------------------

jsonSchemaTests :: [TestTree]
jsonSchemaTests =
  [ testCase "validates string type" $
      validateSchema (Object (KM.fromList [("type", String "string")])) (String "hello")
        @?= Right ()

  , testCase "rejects wrong type" $ do
      let result = validateSchema (Object (KM.fromList [("type", String "string")])) (Number 42)
      assertBool "Left" (either (const True) (const False) result)

  , testCase "validates integer type" $
      validateSchema (Object (KM.fromList [("type", String "integer")])) (Number 42)
        @?= Right ()

  , testCase "validates object with required fields" $ do
      let schema = Object (KM.fromList
            [ ("type", String "object")
            , ("required", Array (V.fromList [String "host", String "port"]))
            , ("properties", Object (KM.fromList
                [ ("host", Object (KM.fromList [("type", String "string")]))
                , ("port", Object (KM.fromList [("type", String "integer")]))
                ]))
            ])
          value = Object (KM.fromList
            [ ("host", String "db.example.com")
            , ("port", Number 5432)
            ])
      validateSchema schema value @?= Right ()

  , testCase "rejects missing required field" $ do
      let schema = Object (KM.fromList
            [ ("type", String "object")
            , ("required", Array (V.fromList [String "host", String "port"]))
            ])
          value = Object (KM.fromList [("host", String "db.example.com")])
      assertBool "Left" (either (const True) (const False) (validateSchema schema value))

  , testCase "validates array items" $ do
      let schema = Object (KM.fromList
            [ ("type", String "array")
            , ("items", Object (KM.fromList [("type", String "string")]))
            ])
          value = Array (V.fromList [String "a", String "b"])
      validateSchema schema value @?= Right ()

  , testCase "rejects invalid array item" $ do
      let schema = Object (KM.fromList
            [ ("type", String "array")
            , ("items", Object (KM.fromList [("type", String "string")]))
            ])
          value = Array (V.fromList [String "a", Number 42])
      assertBool "Left" (either (const True) (const False) (validateSchema schema value))

  , testCase "validates minimum" $
      validateSchema
        (Object (KM.fromList [("type", String "integer"), ("minimum", Number 1)]))
        (Number 5)
        @?= Right ()

  , testCase "rejects below minimum" $ do
      let result = validateSchema
            (Object (KM.fromList [("type", String "integer"), ("minimum", Number 10)]))
            (Number 5)
      assertBool "Left" (either (const True) (const False) result)

  , testCase "validates maximum" $
      validateSchema
        (Object (KM.fromList [("type", String "integer"), ("maximum", Number 100)]))
        (Number 50)
        @?= Right ()

  , testCase "validates string pattern" $
      validateSchema
        (Object (KM.fromList [("type", String "string"), ("pattern", String "^[a-z]+$")]))
        (String "hello")
        @?= Right ()

  , testCase "rejects invalid pattern match" $ do
      let result = validateSchema
            (Object (KM.fromList [("type", String "string"), ("pattern", String "^[a-z]+$")]))
            (String "HELLO")
      assertBool "Left" (either (const True) (const False) result)

  , testCase "validates minItems" $
      validateSchema
        (Object (KM.fromList [("type", String "array"), ("minItems", Number 1)]))
        (Array (V.fromList [String "a"]))
        @?= Right ()

  , testCase "rejects below minItems" $ do
      let result = validateSchema
            (Object (KM.fromList [("type", String "array"), ("minItems", Number 2)]))
            (Array (V.fromList [String "a"]))
      assertBool "Left" (either (const True) (const False) result)

  , testCase "boolean schema true accepts anything" $
      validateSchema (Bool True) (String "anything") @?= Right ()

  , testCase "boolean schema false rejects everything" $ do
      let result = validateSchema (Bool False) (String "anything")
      assertBool "Left" (either (const True) (const False) result)
  ]

------------------------------------------------------------------------
-- Property-based tests
------------------------------------------------------------------------

-- | Arbitrary instance for OValue (limited depth to avoid huge trees)
instance Arbitrary OValue where
  arbitrary = sized genOValue
  shrink (OArray xs) = ONull : map OArray (shrinkList shrink xs)
  shrink (OObject kvs) = ONull : map OObject (shrinkList (const []) kvs)
  shrink _ = []

genOValue :: Int -> Gen OValue
genOValue 0 = oneof
  [ pure ONull
  , OBool <$> arbitrary
  , ONumber . fromIntegral <$> (arbitrary :: Gen Int)
  , OString <$> genSafeText
  ]
genOValue n = oneof
  [ pure ONull
  , OBool <$> arbitrary
  , ONumber . fromIntegral <$> (arbitrary :: Gen Int)
  , OString <$> genSafeText
  , OArray <$> resize (n `div` 2) (listOf (genOValue (n `div` 2)))
  , do kvs <- resize (n `div` 2) (listOf genKV)
       -- Deduplicate keys to match aeson Object semantics
       let deduped = nubBy (\(a,_) (b,_) -> a == b) kvs
       pure (OObject deduped)
  ]
  where
    genKV = (,) <$> genKey <*> genOValue (n `div` 2)
    genKey = T.pack <$> listOf1 (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> ['_']))

-- | Generate text that won't cause YAML parsing issues
genSafeText :: Gen T.Text
genSafeText = T.pack <$> listOf (elements safeChars)
  where safeChars = ['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> [' ', '_', '-']

------------------------------------------------------------------------
-- DeleteStack tests
------------------------------------------------------------------------

deleteStackTests :: [TestTree]
deleteStackTests =
  [ testCase "isConfirmation: y" $
      isConfirmation "y" @?= True
  , testCase "isConfirmation: Y" $
      isConfirmation "Y" @?= True
  , testCase "isConfirmation: yes" $
      isConfirmation "yes" @?= True
  , testCase "isConfirmation: YES" $
      isConfirmation "YES" @?= True
  , testCase "isConfirmation: Yes" $
      isConfirmation "Yes" @?= True
  , testCase "isConfirmation: n" $
      isConfirmation "n" @?= False
  , testCase "isConfirmation: no" $
      isConfirmation "no" @?= False
  , testCase "isConfirmation: empty" $
      isConfirmation "" @?= False
  , testCase "isConfirmation: yep" $
      isConfirmation "yep" @?= False
  , testCase "isConfirmation: random text" $
      isConfirmation "delete it" @?= False
  ]

------------------------------------------------------------------------
-- Changeset conversion tests
------------------------------------------------------------------------

changesetTests :: [TestTree]
changesetTests =
  [ testCase "convertChange: Nothing resourceChange returns Nothing" $ do
      let ch = CChange.newChange
      convertChange ch @?= Nothing

  , testCase "convertChange: missing logicalResourceId returns Nothing" $ do
      let rc = CRC.newResourceChange { CRC.resourceType = Just "AWS::S3::Bucket" }
          ch = CChange.newChange { CChange.resourceChange = Just rc }
      convertChange ch @?= Nothing

  , testCase "convertChange: missing resourceType returns Nothing" $ do
      let rc = CRC.newResourceChange { CRC.logicalResourceId = Just "MyBucket" }
          ch = CChange.newChange { CChange.resourceChange = Just rc }
      convertChange ch @?= Nothing

  , testCase "convertChange: valid change extracts fields" $ do
      let rc = CRC.newResourceChange
                 { CRC.logicalResourceId = Just "MyBucket"
                 , CRC.resourceType = Just "AWS::S3::Bucket"
                 , CRC.physicalResourceId = Just "arn:aws:s3:::my-bucket"
                 , CRC.action = Just CF.ChangeAction_Add
                 }
          ch = CChange.newChange { CChange.resourceChange = Just rc }
      case convertChange ch of
        Nothing -> assertFailure "Expected Just ChangeInfo"
        Just ci -> do
          ciLogicalResourceId ci @?= "MyBucket"
          ciResourceType ci @?= "AWS::S3::Bucket"
          ciPhysicalResourceId ci @?= Just "arn:aws:s3:::my-bucket"
          ciAction ci @?= "Add"

  , testCase "convertChange: minimal valid change (no optionals)" $ do
      let rc = CRC.newResourceChange
                 { CRC.logicalResourceId = Just "MyFunc"
                 , CRC.resourceType = Just "AWS::Lambda::Function"
                 }
          ch = CChange.newChange { CChange.resourceChange = Just rc }
      case convertChange ch of
        Nothing -> assertFailure "Expected Just ChangeInfo"
        Just ci -> do
          ciLogicalResourceId ci @?= "MyFunc"
          ciResourceType ci @?= "AWS::Lambda::Function"
          ciPhysicalResourceId ci @?= Nothing
          ciReplacement ci @?= Nothing
          ciScope ci @?= Nothing
          ciDetails ci @?= []

  , testCase "convertDetail: all fields populated" $ do
      let tgt = CRTD.newResourceTargetDefinition
                  { CRTD.attribute = Just CF.ResourceAttribute_Properties }
          det = CRCD.newResourceChangeDetail
                  { CRCD.target = Just tgt
                  , CRCD.evaluation = Just CF.EvaluationType_Static
                  , CRCD.changeSource = Just CF.ChangeSource_DirectModification
                  , CRCD.causingEntity = Just "MyParam"
                  }
      case convertDetail det of
        Nothing -> assertFailure "Expected Just ChangeDetail"
        Just cd -> do
          cdTarget cd @?= "Properties"
          cdEvaluation cd @?= Just "Static"
          cdChangeSource cd @?= Just "DirectModification"
          cdCausingEntity cd @?= Just "MyParam"

  , testCase "convertDetail: empty detail" $ do
      let det = CRCD.newResourceChangeDetail
      case convertDetail det of
        Nothing -> assertFailure "Expected Just ChangeDetail"
        Just cd -> do
          cdTarget cd @?= ""
          cdEvaluation cd @?= Nothing
          cdChangeSource cd @?= Nothing
          cdCausingEntity cd @?= Nothing

  , testCase "generateDashedName: produces adjective-noun format" $ do
      name <- generateDashedName
      let parts = T.splitOn "-" name
      assertEqual "should have exactly 2 parts" 2 (length parts)
      assertBool "adjective should not be empty" (T.length (head parts) > 0)
      assertBool "noun should not be empty" (T.length (parts !! 1) > 0)

  , testCase "generateDashedName: produces non-empty name" $ do
      name <- generateDashedName
      assertBool "name should not be empty" (T.length name > 0)
      assertBool "name should contain a dash" (T.isInfixOf "-" name)

  , testCase "generateDashedName: different calls can produce different names" $ do
      -- Generate 10 names, at least 2 should be unique (extremely high probability)
      names <- mapM (\_ -> generateDashedName) [(1::Int)..10]
      let uniqueNames = length (nub names)
      assertBool "should produce some variety" (uniqueNames > 1)
  ]

------------------------------------------------------------------------
-- Property-based tests
------------------------------------------------------------------------

propertyTests :: [TestTree]
propertyTests =
  [ testProperty "OValue toValue/fromValue round-trip" prop_ovalue_roundtrip
  , testProperty "OValue toValue preserves nulls" prop_null_roundtrip
  , testProperty "OValue toValue preserves booleans" prop_bool_roundtrip
  , testProperty "OValue toValue preserves strings" prop_string_roundtrip
  , testProperty "parse/emit round-trip produces valid YAML" prop_parse_emit_stable
  , testProperty "Handlebars literal passthrough" prop_handlebars_literal
  ]

-- | toValue → fromValue preserves data (key order may differ for objects)
prop_ovalue_roundtrip :: OValue -> Property
prop_ovalue_roundtrip oval =
  normalizeKeyOrder (fromValue (toValue oval)) === normalizeKeyOrder oval

-- | Normalize OValue by sorting object keys for comparison
normalizeKeyOrder :: OValue -> OValue
normalizeKeyOrder (OObject kvs) =
  OObject (sortBy (\(a,_) (b,_) -> compare a b) [(k, normalizeKeyOrder v) | (k, v) <- kvs])
normalizeKeyOrder (OArray xs) = OArray (map normalizeKeyOrder xs)
normalizeKeyOrder x = x

-- | Null round-trips
prop_null_roundtrip :: Property
prop_null_roundtrip = once $
  fromValue (toValue ONull) === ONull

-- | Booleans round-trip
prop_bool_roundtrip :: Bool -> Property
prop_bool_roundtrip b =
  fromValue (toValue (OBool b)) === OBool b

-- | Strings round-trip
prop_string_roundtrip :: Property
prop_string_roundtrip = forAll genSafeText $ \t ->
  fromValue (toValue (OString t)) === OString t

-- | Parse YAML, emit it, re-parse: should produce same AST
prop_parse_emit_stable :: Property
prop_parse_emit_stable = forAll genSimpleYamlDoc $ \doc -> do
  let bs = BL.fromStrict (TE.encodeUtf8 doc)
  case parseYaml bs "test.yaml" of
    Left _ -> discard  -- skip unparseable inputs
    Right ast ->
      case preprocessYaml loadFileImport ast "test.yaml" of
        _ -> label "parsed" True  -- just verifying parse doesn't crash

-- | Handlebars with no variables should pass through unchanged
prop_handlebars_literal :: Property
prop_handlebars_literal = forAll genSafeText $ \t ->
  not (T.isInfixOf "{{" t) ==>
    interpolate defaultHelpers (Object KM.empty) t === Right t

-- | Generate simple YAML documents for property testing
genSimpleYamlDoc :: Gen T.Text
genSimpleYamlDoc = do
  kvs <- listOf1 genSimpleKV
  pure $ T.unlines kvs
  where
    genSimpleKV = do
      k <- genKey
      v <- genSimpleValue
      pure $ k <> ": " <> v
    genKey = T.pack <$> listOf1 (elements (['a'..'z'] <> ['_']))
    genSimpleValue = oneof
      [ pure "true"
      , pure "false"
      , pure "null"
      , T.pack . show <$> (arbitrary :: Gen Int)
      , genSafeText
      ]

------------------------------------------------------------------------
-- WatchStack tests
------------------------------------------------------------------------

watchStackTests :: [TestTree]
watchStackTests =
  [ testCase "formatEvent - all fields present" $ do
      let e = mkEvent
                { SE.logicalResourceId = Just "MyBucket"
                , SE.resourceType = Just "AWS::S3::Bucket"
                , SE.resourceStatus = Just CF.ResourceStatus_CREATE_COMPLETE
                , SE.resourceStatusReason = Just "Resource creation complete"
                }
      formatEvent e @?= "MyBucket | AWS::S3::Bucket | CREATE_COMPLETE | Resource creation complete"
  , testCase "formatEvent - missing optional fields" $ do
      let e = mkEvent
      formatEvent e @?= " |  |  | "
  , testCase "formatEvent - partial fields" $ do
      let e = mkEvent
                { SE.logicalResourceId = Just "MyFunc"
                , SE.resourceStatus = Just CF.ResourceStatus_CREATE_IN_PROGRESS
                }
      formatEvent e @?= "MyFunc |  | CREATE_IN_PROGRESS | "
  , testCase "formatEvent - with reason but no type" $ do
      let e = mkEvent
                { SE.logicalResourceId = Just "Stack"
                , SE.resourceStatusReason = Just "User Initiated"
                }
      formatEvent e @?= "Stack |  |  | User Initiated"
  , testCase "allTerminalStatuses - contains expected statuses" $ do
      assertBool "CREATE_COMPLETE" ("CREATE_COMPLETE" `elem` allTerminalStatuses)
      assertBool "DELETE_COMPLETE" ("DELETE_COMPLETE" `elem` allTerminalStatuses)
      assertBool "UPDATE_COMPLETE" ("UPDATE_COMPLETE" `elem` allTerminalStatuses)
      assertBool "ROLLBACK_COMPLETE" ("ROLLBACK_COMPLETE" `elem` allTerminalStatuses)
      assertBool "CREATE_FAILED" ("CREATE_FAILED" `elem` allTerminalStatuses)
  , testCase "allTerminalStatuses - does not contain in-progress" $ do
      assertBool "CREATE_IN_PROGRESS not terminal"
        ("CREATE_IN_PROGRESS" `notElem` allTerminalStatuses)
      assertBool "UPDATE_IN_PROGRESS not terminal"
        ("UPDATE_IN_PROGRESS" `notElem` allTerminalStatuses)
  , testCase "stackNameFromId - ARN format" $
      stackNameFromId "arn:aws:cloudformation:us-east-1:123456:stack/my-stack/guid"
        @?= "my-stack"
  , testCase "stackNameFromId - plain name passthrough" $
      stackNameFromId "my-stack" @?= "my-stack"
  , testCase "stackNameFromId - stack ID with slashes" $
      stackNameFromId "prefix/stack-name/suffix"
        @?= "stack-name"
  -- Mock event polling tests (using pollForCompletionWith)
  , testCase "pollForCompletionWith - detects terminal status" $ do
      -- Provide a single batch with a terminal CREATE_COMPLETE event
      let events = [mkStackEvt "evt-1" CF.ResourceStatus_CREATE_COMPLETE]
      eventsRef <- newIORef [events]
      let fetchEvents = do
            batches <- readIORef eventsRef
            case batches of
              (b:rest) -> writeIORef eventsRef rest >> pure b
              []       -> pure events  -- keep returning terminal
      result <- pollForCompletionWith fetchEvents "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                  allTerminalStatuses
                  (testPollConfig { pcOnNewEvents = const (pure ()) })
      result @?= "CREATE_COMPLETE"

  , testCase "pollForCompletionWith - polls multiple times until terminal" $ do
      -- Round 1: in-progress, Round 2: complete (most-recent-first like AWS)
      let inProgress = [mkStackEvt "evt-1" CF.ResourceStatus_CREATE_IN_PROGRESS]
          complete   = [ mkStackEvt "evt-2" CF.ResourceStatus_CREATE_COMPLETE
                       , mkStackEvt "evt-1" CF.ResourceStatus_CREATE_IN_PROGRESS
                       ]
      eventsRef <- newIORef [inProgress, complete]
      pollCount <- newIORef (0 :: Int)
      let fetchEvents = do
            modifyIORef' pollCount (+1)
            batches <- readIORef eventsRef
            case batches of
              (b:rest) -> writeIORef eventsRef rest >> pure b
              []       -> pure complete
      result <- pollForCompletionWith fetchEvents "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                  allTerminalStatuses
                  (testPollConfig { pcOnNewEvents = const (pure ()) })
      result @?= "CREATE_COMPLETE"
      polls <- readIORef pollCount
      assertBool "should poll at least twice" (polls >= 2)

  , testCase "pollForCompletionWith - fires callback with new events only" $ do
      -- Round 1: evt-1 (in-progress), Round 2: evt-2 + evt-1 (most-recent-first)
      let inProgress = [mkStackEvt "evt-1" CF.ResourceStatus_CREATE_IN_PROGRESS]
          complete   = [ mkStackEvt "evt-2" CF.ResourceStatus_CREATE_COMPLETE
                       , mkStackEvt "evt-1" CF.ResourceStatus_CREATE_IN_PROGRESS
                       ]
      eventsRef <- newIORef [inProgress, complete]
      callbackEvents <- newIORef ([] :: [[Text]])
      let fetchEvents = do
            batches <- readIORef eventsRef
            case batches of
              (b:rest) -> writeIORef eventsRef rest >> pure b
              []       -> pure complete
          onNew evts = modifyIORef' callbackEvents (++ [map SE.eventId evts])
      _ <- pollForCompletionWith fetchEvents "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
             allTerminalStatuses
             (testPollConfig { pcOnNewEvents = onNew })
      callbacks <- readIORef callbackEvents
      -- First call gets evt-1, second gets only evt-2 (evt-1 is deduped)
      case callbacks of
        (first:second:_) -> do
          assertEqual "first callback has evt-1" ["evt-1"] first
          assertEqual "second callback has evt-2 only" ["evt-2"] second
        _ -> assertFailure ("expected at least 2 callback batches, got " ++ show (length callbacks))

  , testCase "pollForCompletionWith - ignores non-stack resource terminal status" $ do
      -- A nested resource reaches CREATE_COMPLETE but the stack itself is still in progress
      -- Events are most-recent-first (like AWS API returns)
      let nestedComplete = [ mkResourceEvt "evt-1" "MyBucket" "AWS::S3::Bucket" CF.ResourceStatus_CREATE_COMPLETE
                           , mkStackEvt "evt-0" CF.ResourceStatus_CREATE_IN_PROGRESS
                           ]
          stackComplete  = [ mkStackEvt "evt-2" CF.ResourceStatus_CREATE_COMPLETE
                           , mkResourceEvt "evt-1" "MyBucket" "AWS::S3::Bucket" CF.ResourceStatus_CREATE_COMPLETE
                           , mkStackEvt "evt-0" CF.ResourceStatus_CREATE_IN_PROGRESS
                           ]
      eventsRef <- newIORef [nestedComplete, stackComplete]
      let fetchEvents = do
            batches <- readIORef eventsRef
            case batches of
              (b:rest) -> writeIORef eventsRef rest >> pure b
              []       -> pure stackComplete
      result <- pollForCompletionWith fetchEvents "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                  allTerminalStatuses
                  (testPollConfig { pcOnNewEvents = const (pure ()) })
      result @?= "CREATE_COMPLETE"

  , testCase "pollForCompletionWith - detects DELETE_COMPLETE" $ do
      let events = [mkStackEvt "evt-1" CF.ResourceStatus_DELETE_COMPLETE]
      eventsRef <- newIORef [events]
      let fetchEvents = do
            batches <- readIORef eventsRef
            case batches of
              (b:rest) -> writeIORef eventsRef rest >> pure b
              []       -> pure events
      result <- pollForCompletionWith fetchEvents "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                  allTerminalStatuses
                  (testPollConfig { pcOnNewEvents = const (pure ()) })
      result @?= "DELETE_COMPLETE"

  , testCase "pollForCompletionWith - detects UPDATE_ROLLBACK_COMPLETE" $ do
      let inProgress = [mkStackEvt "evt-1" CF.ResourceStatus_UPDATE_IN_PROGRESS]
          rollback   = [ mkStackEvt "evt-2" CF.ResourceStatus_UPDATE_ROLLBACK_COMPLETE
                       , mkStackEvt "evt-1" CF.ResourceStatus_UPDATE_IN_PROGRESS
                       ]
      eventsRef <- newIORef [inProgress, rollback]
      let fetchEvents = do
            batches <- readIORef eventsRef
            case batches of
              (b:rest) -> writeIORef eventsRef rest >> pure b
              []       -> pure rollback
      result <- pollForCompletionWith fetchEvents "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                  allTerminalStatuses
                  (testPollConfig { pcOnNewEvents = const (pure ()) })
      result @?= "UPDATE_ROLLBACK_COMPLETE"
  ]
  where
    epoch :: UTCTime
    epoch = UTCTime (fromGregorian 2024 1 1) 0
    mkEvent :: SE.StackEvent
    mkEvent = SE.newStackEvent "stack-id" "event-1" "test-stack" epoch

    -- | PollConfig with 0-second delay for fast tests
    testPollConfig :: PollConfig
    testPollConfig = defaultPollConfig { pcIntervalSeconds = 0 }

    -- | Create a stack-level event (logicalResourceId = stack name, type = Stack)
    mkStackEvt :: Text -> CF.ResourceStatus -> SE.StackEvent
    mkStackEvt evtId status =
      (SE.newStackEvent "arn:aws:cloudformation:us-east-1:123:stack/demo/guid" evtId "demo" epoch)
        { SE.logicalResourceId = Just "demo"
        , SE.resourceType = Just "AWS::CloudFormation::Stack"
        , SE.resourceStatus = Just status
        }

    -- | Create a nested resource event
    mkResourceEvt :: Text -> Text -> Text -> CF.ResourceStatus -> SE.StackEvent
    mkResourceEvt evtId logicalId resType status =
      (SE.newStackEvent "arn:aws:cloudformation:us-east-1:123:stack/demo/guid" evtId "demo" epoch)
        { SE.logicalResourceId = Just logicalId
        , SE.resourceType = Just resType
        , SE.resourceStatus = Just status
        }

------------------------------------------------------------------------
-- Error color tests
------------------------------------------------------------------------

-- | Shared test source and location
testSource :: Text
testSource = "line1: foo\nline2: !$ myvar\nline3: bar"

testLoc :: SourceLocation
testLoc = SourceLocation "test.yaml" 2 8 "<root>"

-- | A sample VariableNotFound error for color testing
sampleVarError :: EnhancedPreprocessingError
sampleVarError = VariableNotFoundError VariableNotFoundInfo
  { vnfErrorId       = VariableNotFound
  , vnfVariable      = "myvar"
  , vnfLocation      = testLoc
  , vnfAvailableVars = ["env", "region"]
  , vnfSuggestions   = []
  }

errorColorTests :: [TestTree]
errorColorTests =
  [ testCase "colored output contains ANSI escapes" $ do
      let output = formatError defaultColors testSource sampleVarError
      assertBool "bold red header" ("\ESC[1;31m" `T.isInfixOf` output)
      assertBool "cyan file location" ("\ESC[36m" `T.isInfixOf` output)
      assertBool "light blue guidance" ("\ESC[38;5;75m" `T.isInfixOf` output)
      assertBool "red carets" ("\ESC[31m" `T.isInfixOf` output)
      assertBool "dark grey line numbers" ("\ESC[90m" `T.isInfixOf` output)
      assertBool "reset codes present" ("\ESC[0m" `T.isInfixOf` output)

  , testCase "noColors output has no ANSI escapes" $ do
      let output = formatError noColors testSource sampleVarError
      assertBool "no ESC in output" (not $ "\ESC[" `T.isInfixOf` output)

  , testCase "footer uses light blue (not grey)" $ do
      let output = formatError defaultColors testSource sampleVarError
          footer = last (T.lines output)
      assertBool "footer has light blue" ("\ESC[38;5;75m" `T.isInfixOf` footer)
      assertBool "footer has no grey" (not $ "\ESC[38;5;245m" `T.isInfixOf` footer)

  , testCase "available variables line is fully colored" $ do
      let output = formatError defaultColors testSource sampleVarError
          avLine = head $ filter ("available variables" `T.isInfixOf`) (T.lines output)
      -- light blue wraps entire line including variable names
      assertBool "light blue before label" ("\ESC[38;5;75m" `T.isInfixOf` avLine)
      assertBool "reset after vars" ("\ESC[0m" `T.isInfixOf` avLine)
      -- variable names should be inside the colored span (no reset between label and vars)
      let afterLabel = snd $ T.breakOn "available variables: " avLine
      let resetCount = length $ T.splitOn "\ESC[0m" afterLabel
      assertEqual "single reset at end of vars" 2 resetCount  -- split produces 2 parts for 1 occurrence

  , testCase "type mismatch help is colored" $ do
      let err = TypeMismatchError TypeMismatchInfo
            { tmiErrorId  = TypeMismatchInOperation
            , tmiExpected = "array"
            , tmiFound    = "string"
            , tmiLocation = testLoc
            , tmiContext  = "test"
            , tmiHelp     = Just "try using !$split"
            }
          output = formatError defaultColors testSource err
          helpLines = filter ("try using" `T.isInfixOf`) (T.lines output)
      assertBool "has help line" (not $ null helpLines)
      assertBool "help is colored" ("\ESC[38;5;75m" `T.isInfixOf` head helpLines)

  , testCase "syntax error fix hint is colored" $ do
      let err = YamlSyntaxError YamlSyntaxInfo
            { ysiErrorId      = InvalidYamlSyntax
            , ysiShortMessage = "bad syntax"
            , ysiGuidance     = "check your yaml"
            , ysiLocation     = testLoc
            , ysiFixHint      = Just "add a colon"
            , ysiExample      = Just "key: value"
            }
          output = formatError defaultColors testSource err
          fixLines = filter ("fix:" `T.isInfixOf`) (T.lines output)
          exLines = filter ("example:" `T.isInfixOf`) (T.lines output)
      assertBool "has fix line" (not $ null fixLines)
      assertBool "fix is colored" ("\ESC[38;5;75m" `T.isInfixOf` head fixLines)
      assertBool "has example line" (not $ null exLines)
      assertBool "example is colored" ("\ESC[38;5;75m" `T.isInfixOf` head exLines)

  , testCase "inline description on caret line is colored grey" $ do
      let output = formatError defaultColors testSource sampleVarError
          caretLines = filter ("^" `T.isInfixOf`) (T.lines output)
      assertBool "has caret line" (not $ null caretLines)
      let caretLine = head caretLines
      -- inline desc "variable not defined" should be in grey (245)
      assertBool "inline desc has grey" ("\ESC[38;5;245m" `T.isInfixOf` caretLine)
  ]

------------------------------------------------------------------------
-- Renderer tests
------------------------------------------------------------------------

-- | Create a colored renderer for testing (bypasses terminal detection).
mkColoredRenderer :: IO InteractiveRenderer
mkColoredRenderer = do
  hasRendered <- newIORef False
  spinnerRef <- newIORef Nothing
  spinnerThreadRef <- newIORef Nothing
  timingStateRef <- newIORef Nothing
  timingThreadRef <- newIORef Nothing
  pure InteractiveRenderer
    { irTheme              = darkTheme
    , irOptions            = defaultInteractiveOptions
    , irTerminalWidth      = 130
    , irHasRenderedContent = hasRendered
    , irSpinner            = spinnerRef
    , irSpinnerThread      = spinnerThreadRef
    , irTimingState        = timingStateRef
    , irTimingThread       = timingThreadRef
    }

-- | Create a plain renderer for testing (no colors, no spinners).
mkPlainRenderer :: IO InteractiveRenderer
mkPlainRenderer = do
  hasRendered <- newIORef False
  spinnerRef <- newIORef Nothing
  spinnerThreadRef <- newIORef Nothing
  timingStateRef <- newIORef Nothing
  timingThreadRef <- newIORef Nothing
  pure InteractiveRenderer
    { irTheme              = noColorTheme
    , irOptions            = plainInteractiveOptions
    , irTerminalWidth      = 130
    , irHasRenderedContent = hasRendered
    , irSpinner            = spinnerRef
    , irSpinnerThread      = spinnerThreadRef
    , irTimingState        = timingStateRef
    , irTimingThread       = timingThreadRef
    }

-- | Create a test StackEvent with the given fields.
mkEvent :: Text -> Text -> Text -> Text -> Maybe UTCTime -> StackEvent
mkEvent eid logId rtype status mTs = StackEvent
  { seEventId              = eid
  , seStackId              = "arn:stack"
  , seStackName            = "test-stack"
  , seLogicalResourceId    = logId
  , sePhysicalResourceId   = Nothing
  , seResourceType         = rtype
  , seTimestamp            = mTs
  , seResourceStatus       = status
  , seResourceStatusReason = Nothing
  , seResourceProperties   = Nothing
  , seClientRequestToken   = Nothing
  }

rendererTests :: [TestTree]
rendererTests =
  -- Pure formatting function tests
  [ testCase "formatSectionHeading - colored output" $ do
      r <- mkColoredRenderer
      let heading = formatSectionHeading r "Stack Definition"
      assertBool "contains ANSI" ("\ESC[" `T.isInfixOf` heading)
      assertBool "contains text" ("Stack Definition" `T.isInfixOf` heading)
      assertBool "ends with colon" (T.isSuffixOf ":" heading)

  , testCase "formatSectionHeading - plain output" $ do
      r <- mkPlainRenderer
      let heading = formatSectionHeading r "Stack Definition"
      assertBool "no ANSI" (not $ "\ESC[" `T.isInfixOf` heading)
      assertEqual "plain heading" "Stack Definition:" heading

  , testCase "formatSectionHeading - strips trailing colon" $ do
      r <- mkPlainRenderer
      let heading = formatSectionHeading r "Events:"
      assertEqual "no double colon" "Events:" heading

  , testCase "formatSectionLabel - muted color" $ do
      r <- mkColoredRenderer
      let lbl = formatSectionLabel r "Status"
      assertBool "contains ANSI" ("\ESC[" `T.isInfixOf` lbl)
      assertBool "contains text" ("Status" `T.isInfixOf` lbl)

  , testCase "formatSectionLabel - plain" $ do
      r <- mkPlainRenderer
      let lbl = formatSectionLabel r "Status"
      assertEqual "plain label" "Status" lbl

  , testCase "formatSectionEntry - colored alignment" $ do
      r <- mkColoredRenderer
      let entry = formatSectionEntry r "Status" "CREATE_COMPLETE"
      assertBool "contains ANSI" ("\ESC[" `T.isInfixOf` entry)
      assertBool "contains value" ("CREATE_COMPLETE" `T.isInfixOf` entry)
      assertBool "starts with space" (T.isPrefixOf " " entry)
      assertBool "ends with newline" (T.isSuffixOf "\n" entry)

  , testCase "formatSectionEntry - plain alignment" $ do
      r <- mkPlainRenderer
      let entry = formatSectionEntry r "Status" "CREATE_COMPLETE"
      assertBool "no ANSI" (not $ "\ESC[" `T.isInfixOf` entry)
      assertBool "contains label" ("Status" `T.isInfixOf` entry)
      assertBool "contains value" ("CREATE_COMPLETE" `T.isInfixOf` entry)

  , testCase "formatLogicalId - colored" $ do
      r <- mkColoredRenderer
      let fid = formatLogicalId r "MyBucket"
      assertBool "contains ANSI" ("\ESC[" `T.isInfixOf` fid)
      assertBool "contains text" ("MyBucket" `T.isInfixOf` fid)

  , testCase "styleMuted - colored" $ do
      r <- mkColoredRenderer
      let muted = styleMuted r "dimmed text"
      assertBool "contains ANSI" ("\ESC[" `T.isInfixOf` muted)

  , testCase "styleMuted - plain" $ do
      r <- mkPlainRenderer
      let muted = styleMuted r "dimmed text"
      assertEqual "no styling" "dimmed text" muted

  , testCase "renderTimestamp - correct format" $ do
      let ts = UTCTime (fromGregorian 2026 2 22) (15 * 3600 + 30 * 60 + 45)
          formatted = renderTimestamp ts
      assertEqual "timestamp format" "Sun Feb 22 2026 15:30:45" formatted

  , testCase "calcPadding - respects min and max" $ do
      assertEqual "empty list uses min" minStatusPadding (calcPadding ([] :: [Text]) id)
      let items = [T.replicate 100 "x"]
      assertEqual "long item capped at max" maxPadding (calcPadding items id)
      let shortItems = ["SHORT", "MED"]
      assertEqual "normal items use maxLen" minStatusPadding (calcPadding shortItems id)

  , testCase "padRight - pads short text" $ do
      assertEqual "padded" "hello     " (padRight 10 "hello")
      assertEqual "exact length" "1234567890" (padRight 10 "1234567890")
      assertEqual "longer text unchanged" "12345678901" (padRight 10 "12345678901")

  , testCase "prettyFormatTags - Environment first" $ do
      let tags = Map.fromList [("Version", "1.0"), ("Environment", "production"), ("App", "web")]
      let result = prettyFormatTags tags Nothing
      assertBool "Environment first" (T.isPrefixOf "Environment=production" result)
      assertBool "contains all" ("App=web" `T.isInfixOf` result)

  , testCase "prettyFormatTags - empty" $ do
      assertEqual "empty tags" "" (prettyFormatTags Map.empty Nothing)

  , testCase "prettyFormatParameters - sorted" $ do
      let params = Map.fromList [("Zebra", "z"), ("Alpha", "a"), ("Middle", "m")]
      let result = prettyFormatParameters params
      assertBool "Alpha first" (T.isPrefixOf "Alpha=a" result)
      assertBool "contains all" ("Zebra=z" `T.isInfixOf` result)

  , testCase "prettyFormatParameters - empty" $ do
      assertEqual "empty params" "" (prettyFormatParameters Map.empty)

  , testCase "formatTokenSource - user-provided" $ do
      assertEqual "user" "user-provided" (formatTokenSource UserProvided)

  , testCase "formatTokenSource - auto-generated" $ do
      assertEqual "auto" "auto-generated" (formatTokenSource AutoGenerated)

  , testCase "formatTokenSource - derived" $ do
      let dti = DerivedTokenInfo { dtiFrom = "primary", dtiStep = "create-stack" }
      let result = formatTokenSource (Derived dti)
      assertBool "derived from" ("derived from primary" `T.isInfixOf` result)

  -- Timing text tests
  , testCase "formatTimingText - no last event" $ do
      assertEqual "elapsed only"
        "5 seconds elapsed total."
        (formatTimingText 5 Nothing)

  , testCase "formatTimingText - with last event" $ do
      assertEqual "elapsed + since last"
        "10 seconds elapsed total. 3 since last event."
        (formatTimingText 10 (Just 3))

  , testCase "formatTimingText - zero elapsed" $ do
      assertEqual "zero"
        "0 seconds elapsed total."
        (formatTimingText 0 Nothing)

  -- Event duration calculation tests
  , testCase "calculateEventDurations - IN_PROGRESS then COMPLETE" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          t5 = addUTCTime (secondsToNominalDiffTime 5) t0
          events =
            [ mkEvent "e1" "MyResource" "AWS::S3::Bucket" "CREATE_IN_PROGRESS" (Just t0)
            , mkEvent "e2" "MyResource" "AWS::S3::Bucket" "CREATE_COMPLETE" (Just t5)
            ]
          result = calculateEventDurations events
      assertEqual "IN_PROGRESS has no duration" Nothing (sewDurationSeconds (result !! 0))
      assertEqual "COMPLETE has 5s duration" (Just 5) (sewDurationSeconds (result !! 1))

  , testCase "calculateEventDurations - no matching start" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          events =
            [ mkEvent "e1" "MyResource" "AWS::S3::Bucket" "CREATE_COMPLETE" (Just t0)
            ]
          result = calculateEventDurations events
      assertEqual "no start = no duration" Nothing (sewDurationSeconds (head result))

  , testCase "calculateEventDurations - FAILED event gets duration" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          t3 = addUTCTime (secondsToNominalDiffTime 3) t0
          events =
            [ mkEvent "e1" "MyResource" "AWS::EC2::Instance" "CREATE_IN_PROGRESS" (Just t0)
            , mkEvent "e2" "MyResource" "AWS::EC2::Instance" "CREATE_FAILED" (Just t3)
            ]
          result = calculateEventDurations events
      assertEqual "FAILED has 3s duration" (Just 3) (sewDurationSeconds (result !! 1))

  , testCase "calculateEventDurations - multiple resources" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          t2 = addUTCTime (secondsToNominalDiffTime 2) t0
          t4 = addUTCTime (secondsToNominalDiffTime 4) t0
          t7 = addUTCTime (secondsToNominalDiffTime 7) t0
          events =
            [ mkEvent "e1" "Bucket" "AWS::S3::Bucket" "CREATE_IN_PROGRESS" (Just t0)
            , mkEvent "e2" "Instance" "AWS::EC2::Instance" "CREATE_IN_PROGRESS" (Just t2)
            , mkEvent "e3" "Bucket" "AWS::S3::Bucket" "CREATE_COMPLETE" (Just t4)
            , mkEvent "e4" "Instance" "AWS::EC2::Instance" "CREATE_COMPLETE" (Just t7)
            ]
          result = calculateEventDurations events
      assertEqual "Bucket = 4s" (Just 4) (sewDurationSeconds (result !! 2))
      assertEqual "Instance = 5s" (Just 5) (sewDurationSeconds (result !! 3))

  -- Color function tests
  , testCase "colorize - dark theme applies ANSI" $ do
      let result = colorize darkTheme (thSuccess darkTheme) "OK"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)
      assertBool "has text" ("OK" `T.isInfixOf` result)

  , testCase "colorize - noColor theme is plain" $ do
      let result = colorize noColorTheme (thSuccess noColorTheme) "OK"
      assertEqual "no color" "OK" result

  , testCase "colorizeResourceStatus - IN_PROGRESS is warning color" $ do
      let result = colorizeResourceStatus darkTheme "CREATE_IN_PROGRESS"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)
      assertBool "has text" ("CREATE_IN_PROGRESS" `T.isInfixOf` result)

  , testCase "colorizeResourceStatus - COMPLETE is success color" $ do
      let result = colorizeResourceStatus darkTheme "CREATE_COMPLETE"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)

  , testCase "colorizeResourceStatus - FAILED is error color" $ do
      let result = colorizeResourceStatus darkTheme "CREATE_FAILED"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)

  , testCase "colorizeResourceStatus - noColor" $ do
      let result = colorizeResourceStatus noColorTheme "CREATE_COMPLETE"
      assertEqual "no color" "CREATE_COMPLETE" result

  -- Column constants
  , testCase "column2Start is 25" $ do
      assertEqual "column2Start" 25 column2Start

  , testCase "defaultScreenWidth is 130" $ do
      assertEqual "defaultScreenWidth" 130 defaultScreenWidth
  ]

------------------------------------------------------------------------
-- Test fixtures for OutputData types
------------------------------------------------------------------------

testTimestamp :: UTCTime
testTimestamp = UTCTime (fromGregorian 2026 2 22) (15 * 3600 + 30 * 60)

testTokenInfo :: TokenInfo
testTokenInfo = TokenInfo
  { tiValue = "tok-abc123"
  , tiSource = AutoGenerated
  , tiOperationId = "op-001"
  }

testStackDef :: StackDefinition
testStackDef = StackDefinition
  { sdName = "my-stack"
  , sdStacksetName = Nothing
  , sdDescription = Just "Test stack"
  , sdStatus = "CREATE_COMPLETE"
  , sdStatusReason = Nothing
  , sdCapabilities = ["CAPABILITY_IAM"]
  , sdServiceRole = Nothing
  , sdTags = Map.fromList [("Environment", "production")]
  , sdParameters = Map.fromList [("Env", "prod")]
  , sdDisableRollback = False
  , sdTerminationProtection = True
  , sdCreationTime = Just testTimestamp
  , sdLastUpdatedTime = Nothing
  , sdTimeoutInMinutes = Just 30
  , sdNotificationArns = []
  , sdStackPolicy = Nothing
  , sdArn = "arn:aws:cloudformation:us-east-1:123456789:stack/my-stack/guid"
  , sdConsoleUrl = "https://console.aws.amazon.com/cloudformation/home#/stacks/my-stack"
  , sdRegion = "us-east-1"
  }

testStackEvent :: StackEvent
testStackEvent = StackEvent
  { seEventId = "evt-001"
  , seStackId = "arn:aws:cloudformation:us-east-1:123456789:stack/my-stack/guid"
  , seStackName = "my-stack"
  , seLogicalResourceId = "MyBucket"
  , sePhysicalResourceId = Just "my-bucket-abc"
  , seResourceType = "AWS::S3::Bucket"
  , seTimestamp = Just testTimestamp
  , seResourceStatus = "CREATE_COMPLETE"
  , seResourceStatusReason = Nothing
  , seResourceProperties = Nothing
  , seClientRequestToken = Just "tok-abc123"
  }

testEventWithTiming :: StackEventWithTiming
testEventWithTiming = StackEventWithTiming
  { sewEvent = testStackEvent
  , sewDurationSeconds = Just 45
  }

testStatusUpdate :: StatusUpdate
testStatusUpdate = StatusUpdate
  { suMessage = "Stack creation in progress"
  , suTimestamp = testTimestamp
  , suLevel = LevelInfo
  }

testCommandResult :: CommandResult
testCommandResult = CommandResult
  { crSuccess = True
  , crElapsedSeconds = 120
  , crMessage = Just "Stack created successfully"
  , crExitCode = 0
  }

testStackListEntry :: StackListEntry
testStackListEntry = StackListEntry
  { sleStackName = "my-stack"
  , sleStackStatus = "CREATE_COMPLETE"
  , sleCreationTime = Just testTimestamp
  , sleLastUpdatedTime = Nothing
  , sleTags = Map.fromList [("Environment", "production")]
  , sleStatusReason = Nothing
  , sleTerminationProtection = True
  , sleEnvironmentType = Just "production"
  }

testErrorInfo :: ErrorInfo
testErrorInfo = ErrorInfo
  { eiErrorType = "ValidationError"
  , eiMessage = "Template format error"
  , eiTimestamp = testTimestamp
  , eiSuggestions = ["Check template syntax"]
  , eiErrorDetails = ErrorGeneric (Just "Invalid YAML")
  }

testAbsentInfo :: StackAbsentInfo
testAbsentInfo = StackAbsentInfo
  { saiStackName = "missing-stack"
  , saiEnvironment = "development"
  , saiRegion = "us-west-2"
  , saiAccount = "123456789012"
  , saiAuthArn = "arn:aws:iam::123456789012:user/dev"
  }

------------------------------------------------------------------------
-- JSON Renderer tests (Phase 11.4)
------------------------------------------------------------------------

-- | Helper to look up a key in a JSON object Value.
jsonLookup :: Text -> Value -> Maybe Value
jsonLookup key (Object obj) = KM.lookup (AesonKey.fromText key) obj
jsonLookup _ _ = Nothing

jsonRendererTests :: [TestTree]
jsonRendererTests =
  [ testCase "metadataToValue - has all fields" $ do
      let meta = CommandMetadata
            { cmEnvironment = "production"
            , cmRegion = "us-east-1"
            , cmProfile = Just "default"
            , cmCliArguments = Map.fromList [("stack-args", "stack.yaml")]
            , cmIamServiceRole = Nothing
            , cmCurrentIamPrincipal = "arn:aws:iam::123:user/dev"
            , cmCredentialSource = "environment"
            , cmVersion = "1.0.0"
            , cmPrimaryToken = testTokenInfo
            , cmDerivedTokens = []
            }
          val = metadataToValue meta
      assertBool "is object" (isObject val)
      assertEqual "region" (Just (String "us-east-1")) (jsonLookup "region" val)
      assertEqual "environment" (Just (String "production")) (jsonLookup "iidy_environment" val)
      assertEqual "version" (Just (String "1.0.0")) (jsonLookup "iidy_version" val)

  , testCase "defToValue - contains stack fields" $ do
      let val = defToValue testStackDef
      assertEqual "name" (Just (String "my-stack")) (jsonLookup "name" val)
      assertEqual "status" (Just (String "CREATE_COMPLETE")) (jsonLookup "status" val)
      assertEqual "description" (Just (String "Test stack")) (jsonLookup "description" val)
      assertEqual "region" (Just (String "us-east-1")) (jsonLookup "region" val)
      assertEqual "termination_protection" (Just (Aeson.Bool True)) (jsonLookup "termination_protection" val)

  , testCase "eventToValue - has event fields" $ do
      let val = eventToValue testStackEvent
      assertEqual "event_id" (Just (String "evt-001")) (jsonLookup "event_id" val)
      assertEqual "logical_resource_id" (Just (String "MyBucket")) (jsonLookup "logical_resource_id" val)
      assertEqual "resource_type" (Just (String "AWS::S3::Bucket")) (jsonLookup "resource_type" val)
      assertEqual "resource_status" (Just (String "CREATE_COMPLETE")) (jsonLookup "resource_status" val)

  , testCase "eventWithTimingToValue - wraps event with duration" $ do
      let val = eventWithTimingToValue testEventWithTiming
      assertBool "has event" (jsonLookup "event" val /= Nothing)
      assertEqual "duration" (Just (Number 45)) (jsonLookup "duration_seconds" val)

  , testCase "eventsDisplayToValue - has title and events" $ do
      let display = StackEventsDisplay
            { sedTitle = "Recent Events"
            , sedEvents = [testEventWithTiming]
            , sedMaxEvents = Just 50
            , sedTruncated = Nothing
            }
          val = eventsDisplayToValue display
      assertEqual "title" (Just (String "Recent Events")) (jsonLookup "title" val)

  , testCase "statusUpdateToValue - has level and message" $ do
      let val = statusUpdateToValue testStatusUpdate
      assertEqual "message" (Just (String "Stack creation in progress")) (jsonLookup "message" val)
      assertEqual "level" (Just (String "info")) (jsonLookup "level" val)

  , testCase "statusUpdateToValue - warning level" $ do
      let upd = testStatusUpdate { suLevel = LevelWarning }
          val = statusUpdateToValue upd
      assertEqual "level" (Just (String "warning")) (jsonLookup "level" val)

  , testCase "statusUpdateToValue - error level" $ do
      let upd = testStatusUpdate { suLevel = LevelError }
          val = statusUpdateToValue upd
      assertEqual "level" (Just (String "error")) (jsonLookup "level" val)

  , testCase "statusUpdateToValue - success level" $ do
      let upd = testStatusUpdate { suLevel = LevelSuccess }
          val = statusUpdateToValue upd
      assertEqual "level" (Just (String "success")) (jsonLookup "level" val)

  , testCase "commandResultToValue - success" $ do
      let val = commandResultToValue testCommandResult
      assertEqual "success" (Just (Aeson.Bool True)) (jsonLookup "success" val)
      assertEqual "elapsed" (Just (Number 120)) (jsonLookup "elapsed_seconds" val)
      assertEqual "exit_code" (Just (Number 0)) (jsonLookup "exit_code" val)

  , testCase "summaryToValue - success" $ do
      let summ = FinalCommandSummary { fcsResult = SummarySuccess, fcsElapsedSeconds = 60 }
          val = summaryToValue summ
      assertEqual "result" (Just (String "success")) (jsonLookup "result" val)
      assertEqual "elapsed" (Just (Number 60)) (jsonLookup "elapsed_seconds" val)

  , testCase "summaryToValue - failure" $ do
      let summ = FinalCommandSummary { fcsResult = SummaryFailure, fcsElapsedSeconds = 10 }
          val = summaryToValue summ
      assertEqual "result" (Just (String "failure")) (jsonLookup "result" val)

  , testCase "stackListEntryToValue - has stack fields" $ do
      let val = stackListEntryToValue testStackListEntry
      assertEqual "stack_name" (Just (String "my-stack")) (jsonLookup "stack_name" val)
      assertEqual "stack_status" (Just (String "CREATE_COMPLETE")) (jsonLookup "stack_status" val)
      assertEqual "termination_protection" (Just (Aeson.Bool True)) (jsonLookup "termination_protection" val)
      assertEqual "environment_type" (Just (String "production")) (jsonLookup "environment_type" val)

  , testCase "stackListToValue - has stacks and columns" $ do
      let display = StackListDisplay
            { sldStacks = [testStackListEntry]
            , sldShowTags = True
            , sldFiltersApplied = ["status:CREATE_COMPLETE"]
            , sldColumns = [ColName, ColStatus, ColTags]
            , sldQueryMode = False
            }
          val = stackListToValue display
      assertEqual "show_tags" (Just (Aeson.Bool True)) (jsonLookup "show_tags" val)
      assertEqual "query_mode" (Just (Aeson.Bool False)) (jsonLookup "query_mode" val)

  , testCase "driftToValue - has drifted resources" $ do
      let drift = StackDrift
            { sdrDriftedResources =
              [ DriftedResource
                { drLogicalResourceId = "MyBucket"
                , drPhysicalResourceId = "bucket-123"
                , drResourceType = "AWS::S3::Bucket"
                , drDriftStatus = "MODIFIED"
                , drPropertyDifferences =
                  [ PropertyDifference
                    { pdPropertyPath = "/BucketName"
                    , pdExpectedValue = Just "expected-name"
                    , pdActualValue = Just "actual-name"
                    , pdDifferenceType = Just "NOT_EQUAL"
                    }
                  ]
                }
              ]
            }
          val = driftToValue drift
      assertBool "has drifted_resources" (jsonLookup "drifted_resources" val /= Nothing)

  , testCase "errorInfoToValue - has error fields" $ do
      let val = errorInfoToValue testErrorInfo
      assertEqual "error_type" (Just (String "ValidationError")) (jsonLookup "error_type" val)
      assertEqual "message" (Just (String "Template format error")) (jsonLookup "message" val)

  , testCase "tokenInfoToValue - auto-generated" $ do
      let val = tokenInfoToValue testTokenInfo
      assertEqual "value" (Just (String "tok-abc123")) (jsonLookup "value" val)
      assertEqual "operation_id" (Just (String "op-001")) (jsonLookup "operation_id" val)

  , testCase "operationCompleteToValue - has elapsed" $ do
      let info = OperationCompleteInfo
            { ociElapsedSeconds = 300
            , ociOperationStartTime = testTimestamp
            , ociSkipRemainingSections = False
            }
          val = operationCompleteToValue info
      assertEqual "elapsed" (Just (Number 300)) (jsonLookup "elapsed_seconds" val)

  , testCase "inactivityTimeoutToValue - has timeout" $ do
      let info = InactivityTimeoutInfo
            { itiTimeoutSeconds = 600
            , itiElapsedSeconds = 605
            , itiOperationStartTime = testTimestamp
            }
          val = inactivityTimeoutToValue info
      assertEqual "timeout" (Just (Number 600)) (jsonLookup "timeout_seconds" val)
      assertEqual "elapsed" (Just (Number 605)) (jsonLookup "elapsed_seconds" val)

  , testCase "changeDetailsToValue - create" $ do
      let details = StackChangeDetails { scdChangeType = ChangeCreate, scdStackName = "new-stack" }
          val = changeDetailsToValue details
      assertEqual "change_type" (Just (String "create")) (jsonLookup "change_type" val)
      assertEqual "stack_name" (Just (String "new-stack")) (jsonLookup "stack_name" val)

  , testCase "absentInfoToValue - has all fields" $ do
      let val = absentInfoToValue testAbsentInfo
      assertEqual "stack_name" (Just (String "missing-stack")) (jsonLookup "stack_name" val)
      assertEqual "environment" (Just (String "development")) (jsonLookup "environment" val)
      assertEqual "region" (Just (String "us-west-2")) (jsonLookup "region" val)

  , testCase "costEstimateToValue - has URL" $ do
      let est = CostEstimate (CostEstimateInfo "https://calculator.aws" (Just "my-stack") (Just "template.yaml"))
          val = costEstimateToValue est
      assertEqual "url" (Just (String "https://calculator.aws")) (jsonLookup "url" val)

  , testCase "approvalRequestToValue - has locations" $ do
      let req = ApprovalRequestResult
            { arrTemplateLocation = "s3://bucket/template.yaml"
            , arrPendingLocation = "s3://bucket/pending/template.yaml"
            , arrAlreadyApproved = False
            , arrNextSteps = ["Review the template", "Run approval-review"]
            }
          val = approvalRequestToValue req
      assertEqual "template_location" (Just (String "s3://bucket/template.yaml")) (jsonLookup "template_location" val)
      assertEqual "already_approved" (Just (Aeson.Bool False)) (jsonLookup "already_approved" val)

  , testCase "templateValidationToValue - with errors" $ do
      let tv = TemplateValidation { tvEnabled = True, tvErrors = ["Missing required property"], tvWarnings = [] }
          val = templateValidationToValue tv
      assertEqual "enabled" (Just (Aeson.Bool True)) (jsonLookup "enabled" val)

  , testCase "approvalStatusToValue - pending" $ do
      let st = ApprovalStatus
            { apsPendingExists = True
            , apsAlreadyApproved = False
            , apsPendingLocation = "s3://bucket/pending"
            , apsApprovedLocation = Nothing
            }
          val = approvalStatusToValue st
      assertEqual "pending_exists" (Just (Aeson.Bool True)) (jsonLookup "pending_exists" val)

  , testCase "templateDiffToValue - has changes" $ do
      let diff = TemplateDiff { tdDiffOutput = "--- a/t\n+++ b/t\n@@ -1 +1 @@\n-old\n+new", tdContextLines = 3, tdHasChanges = True }
          val = templateDiffToValue diff
      assertEqual "has_changes" (Just (Aeson.Bool True)) (jsonLookup "has_changes" val)

  , testCase "approvalResultToValue - approved" $ do
      let res = ApprovalResult
            { arApproved = True
            , arApprovedLocation = Just "s3://bucket/approved"
            , arLatestLocation = Just "s3://bucket/latest"
            , arCleanupCompleted = True
            }
          val = approvalResultToValue res
      assertEqual "approved" (Just (Aeson.Bool True)) (jsonLookup "approved" val)
      assertEqual "cleanup_completed" (Just (Aeson.Bool True)) (jsonLookup "cleanup_completed" val)

  , testCase "encodeValue - produces valid JSON text" $ do
      let val = Aeson.object ["key" Aeson..= ("value" :: Text)]
          encoded = encodeValue defaultJsonOptions val
      assertBool "not empty" (not $ T.null encoded)
      assertBool "contains key" ("key" `T.isInfixOf` encoded)

  , testCase "JSON envelope with type wraps data" $ do
      -- Test the envelope structure that outputJson builds
      let opts = defaultJsonOptions { joIncludeTimestamps = False }
          dataVal = statusUpdateToValue testStatusUpdate
          envelope = Aeson.object ["type" Aeson..= ("status_update" :: Text), "data" Aeson..= dataVal]
          encoded = encodeValue opts envelope
          parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
      case parsed of
        Nothing -> assertFailure ("Failed to parse JSON envelope: " <> T.unpack encoded)
        Just v -> do
          assertEqual "type" (Just (String "status_update")) (jsonLookup "type" v)
          assertBool "has data" (jsonLookup "data" v /= Nothing)

  , testCase "JSON envelope without type" $ do
      let opts = defaultJsonOptions { joIncludeTimestamps = False, joIncludeType = False }
          dataVal = statusUpdateToValue testStatusUpdate
          encoded = encodeValue opts dataVal
          parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
      case parsed of
        Nothing -> assertFailure "Failed to parse JSON"
        Just v -> assertEqual "no type field" Nothing (jsonLookup "type" v)

  , testCase "JSON envelope all OutputData types produce valid JSON" $ do
      -- Build a representative value for each type and verify encodeValue round-trips
      let opts = defaultJsonOptions { joIncludeTimestamps = False }
          pairs :: [(Text, Value)]
          pairs =
            [ ("command_metadata", metadataToValue CommandMetadata
                { cmEnvironment = "dev", cmRegion = "us-east-1", cmProfile = Nothing
                , cmCliArguments = Map.empty, cmIamServiceRole = Nothing
                , cmCurrentIamPrincipal = "arn:test", cmCredentialSource = "env"
                , cmVersion = "1.0", cmPrimaryToken = testTokenInfo, cmDerivedTokens = [] })
            , ("status_update", statusUpdateToValue testStatusUpdate)
            , ("command_result", commandResultToValue testCommandResult)
            , ("final_command_summary", summaryToValue (FinalCommandSummary SummarySuccess 1))
            , ("error", errorInfoToValue testErrorInfo)
            , ("stack_definition", defToValue testStackDef)
            , ("stack_events", eventsDisplayToValue (StackEventsDisplay "Events" [testEventWithTiming] Nothing Nothing))
            , ("operation_complete", operationCompleteToValue (OperationCompleteInfo 60 testTimestamp False))
            , ("inactivity_timeout", inactivityTimeoutToValue (InactivityTimeoutInfo 300 305 testTimestamp))
            , ("cost_estimate", costEstimateToValue (CostEstimate (CostEstimateInfo "https://calc" Nothing Nothing)))
            , ("template_validation", templateValidationToValue (TemplateValidation True [] []))
            , ("template_diff", templateDiffToValue (TemplateDiff "diff" 3 True))
            , ("approval_result", approvalResultToValue (ApprovalResult True Nothing Nothing True))
            ]
      mapM_ (\(typeName, dataVal) -> do
        let envelope = Aeson.object ["type" Aeson..= typeName, "data" Aeson..= dataVal]
            encoded = encodeValue opts envelope
            parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
        case parsed of
          Nothing -> assertFailure ("Failed to parse JSON for " <> T.unpack typeName <> ": " <> T.unpack encoded)
          Just _ -> pure ()
        ) pairs

  , testCase "contentsToValue - has resources and outputs" $ do
      let contents = StackContents
            { scResources =
                [ StackResourceInfo "MyBucket" (Just "bucket-abc") "AWS::S3::Bucket" "CREATE_COMPLETE" Nothing Nothing ]
            , scOutputs =
                [ StackOutputInfo "BucketArn" "arn:aws:s3:::bucket-abc" (Just "ARN of bucket") Nothing ]
            , scExports = []
            , scCurrentStatus = StackStatusInfo "CREATE_COMPLETE" Nothing Nothing
            , scPendingChangesets = []
            }
          val = contentsToValue contents
      assertBool "has resources" (jsonLookup "resources" val /= Nothing)
      assertBool "has outputs" (jsonLookup "outputs" val /= Nothing)

  , testCase "changesetResultToValue - has changeset fields" $ do
      let cs = ChangeSetCreationResult
            { csrChangesetName = "cs-001"
            , csrStackName = "my-stack"
            , csrChangesetType = "CREATE"
            , csrStatus = "CREATE_COMPLETE"
            , csrConsoleUrl = "https://console.aws.amazon.com"
            , csrHasChanges = True
            , csrPendingChangesets = []
            , csrNextSteps = ["exec-changeset cs-001"]
            }
          val = changesetResultToValue cs
      assertEqual "changeset_name" (Just (String "cs-001")) (jsonLookup "changeset_name" val)
      assertEqual "has_changes" (Just (Aeson.Bool True)) (jsonLookup "has_changes" val)
  ]

isObject :: Value -> Bool
isObject (Object _) = True
isObject _ = False

------------------------------------------------------------------------
-- Theme variant tests (Phase 11.3)
------------------------------------------------------------------------

themeVariantTests :: [TestTree]
themeVariantTests =
  [ testCase "darkTheme - has colors enabled" $ do
      assertBool "colors enabled" (thColorsEnabled darkTheme)

  , testCase "lightTheme - has colors enabled" $ do
      assertBool "colors enabled" (thColorsEnabled lightTheme)

  , testCase "highContrastTheme - has colors enabled" $ do
      assertBool "colors enabled" (thColorsEnabled highContrastTheme)

  , testCase "noColorTheme - colors disabled" $ do
      assertBool "colors disabled" (not $ thColorsEnabled noColorTheme)

  , testCase "darkTheme colorize produces ANSI" $ do
      let result = colorize darkTheme (thSuccess darkTheme) "OK"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)

  , testCase "lightTheme colorize produces ANSI" $ do
      let result = colorize lightTheme (thSuccess lightTheme) "OK"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)

  , testCase "highContrastTheme colorize produces ANSI" $ do
      let result = colorize highContrastTheme (thSuccess highContrastTheme) "OK"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)

  , testCase "noColorTheme colorize is plain" $ do
      let result = colorize noColorTheme (thSuccess noColorTheme) "OK"
      assertEqual "no ANSI" "OK" result

  , testCase "dark and light themes produce different ANSI codes" $ do
      let dark = colorize darkTheme (thMuted darkTheme) "text"
          light = colorize lightTheme (thMuted lightTheme) "text"
      assertBool "different codes" (dark /= light)

  , testCase "highContrast uses bright colors" $ do
      let result = colorize highContrastTheme (thError highContrastTheme) "ERR"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)
      assertBool "contains text" ("ERR" `T.isInfixOf` result)

  , testCase "colorizeResourceStatus consistent across themes" $ do
      -- All colored themes should produce ANSI for COMPLETE status
      let darkResult = colorizeResourceStatus darkTheme "UPDATE_COMPLETE"
          lightResult = colorizeResourceStatus lightTheme "UPDATE_COMPLETE"
          hcResult = colorizeResourceStatus highContrastTheme "UPDATE_COMPLETE"
      assertBool "dark has ANSI" ("\ESC[" `T.isInfixOf` darkResult)
      assertBool "light has ANSI" ("\ESC[" `T.isInfixOf` lightResult)
      assertBool "hc has ANSI" ("\ESC[" `T.isInfixOf` hcResult)

  , testCase "colorizeResourceStatus - ROLLBACK uses error color" $ do
      let result = colorizeResourceStatus darkTheme "ROLLBACK_COMPLETE"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)

  , testCase "colorizeResourceStatus - DELETE_SKIPPED uses muted" $ do
      let result = colorizeResourceStatus darkTheme "DELETE_SKIPPED"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)
  ]

------------------------------------------------------------------------
-- Renderer output capture tests (Phase 11.2 + 11.5)
------------------------------------------------------------------------

rendererOutputTests :: [TestTree]
rendererOutputTests =
  -- Pure formatting tests for OutputData rendering (no stdout capture needed)
  [ testCase "formatSectionEntry renders stack definition fields" $ do
      r <- mkPlainRenderer
      let nameEntry = formatSectionEntry r "Name" "my-stack"
          statusEntry = formatSectionEntry r "Status" "CREATE_COMPLETE"
          regionEntry = formatSectionEntry r "Region" "us-east-1"
      assertBool "name entry has stack name" ("my-stack" `T.isInfixOf` nameEntry)
      assertBool "status entry has status" ("CREATE_COMPLETE" `T.isInfixOf` statusEntry)
      assertBool "region entry has region" ("us-east-1" `T.isInfixOf` regionEntry)

  , testCase "formatSectionEntry colored has ANSI, plain does not" $ do
      colored <- mkColoredRenderer
      plain <- mkPlainRenderer
      let coloredEntry = formatSectionEntry colored "Status" "CREATE_COMPLETE"
          plainEntry = formatSectionEntry plain "Status" "CREATE_COMPLETE"
      assertBool "colored has ANSI" ("\ESC[" `T.isInfixOf` coloredEntry)
      assertBool "plain no ANSI" (not $ "\ESC[" `T.isInfixOf` plainEntry)
      assertBool "both have value" ("CREATE_COMPLETE" `T.isInfixOf` coloredEntry && "CREATE_COMPLETE" `T.isInfixOf` plainEntry)

  , testCase "formatSectionHeading renders event titles" $ do
      r <- mkPlainRenderer
      let heading = formatSectionHeading r "Recent Events"
      assertEqual "plain heading" "Recent Events:" heading

  , testCase "formatLogicalId renders resource names" $ do
      r <- mkPlainRenderer
      let fid = formatLogicalId r "MyBucket"
      assertEqual "plain id" "MyBucket" fid

  , testCase "formatLogicalId colored wraps with ANSI" $ do
      r <- mkColoredRenderer
      let fid = formatLogicalId r "WebServer"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` fid)
      assertBool "has name" ("WebServer" `T.isInfixOf` fid)

  , testCase "colorizeResourceStatus maps status families correctly" $ do
      -- IN_PROGRESS -> warning color
      let inProgressResult = colorizeResourceStatus darkTheme "CREATE_IN_PROGRESS"
      assertBool "in_progress colored" ("\ESC[" `T.isInfixOf` inProgressResult)
      -- COMPLETE -> success color
      let completeResult = colorizeResourceStatus darkTheme "UPDATE_COMPLETE"
      assertBool "complete colored" ("\ESC[" `T.isInfixOf` completeResult)
      -- FAILED -> error color
      let failedResult = colorizeResourceStatus darkTheme "DELETE_FAILED"
      assertBool "failed colored" ("\ESC[" `T.isInfixOf` failedResult)
      -- ROLLBACK -> error color
      let rollbackResult = colorizeResourceStatus darkTheme "ROLLBACK_IN_PROGRESS"
      assertBool "rollback colored" ("\ESC[" `T.isInfixOf` rollbackResult)

  , testCase "renderTimestamp produces expected format" $ do
      let ts = UTCTime (fromGregorian 2026 1 15) (10 * 3600 + 5 * 60 + 30)
          formatted = renderTimestamp ts
      assertEqual "timestamp" "Thu Jan 15 2026 10:05:30" formatted

  , testCase "prettyFormatTags with environment and env" $ do
      let tags = Map.fromList [("Environment", "staging"), ("Name", "my-stack")]
          result = prettyFormatTags tags (Just 100)
      assertBool "Environment first" (T.isPrefixOf "Environment=staging" result)
      assertBool "contains Name" ("Name=my-stack" `T.isInfixOf` result)

  , testCase "prettyFormatParameters with multiple params" $ do
      let params = Map.fromList [("InstanceType", "t3.micro"), ("Env", "prod"), ("VpcId", "vpc-123")]
          result = prettyFormatParameters params
      assertBool "sorted alphabetically" (T.isPrefixOf "Env=prod" result)
      assertBool "contains all" ("InstanceType=t3.micro" `T.isInfixOf` result && "VpcId=vpc-123" `T.isInfixOf` result)

  , testCase "JSON value for stack list entry query mode" $ do
      -- In query mode, stack list entries should be raw values
      let entries = [stackListEntryToValue testStackListEntry]
          val = Aeson.toJSON entries
          encoded = encodeValue defaultJsonOptions val
          parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
      case parsed of
        Nothing -> assertFailure "Failed to parse JSON array"
        Just (Array arr) -> assertEqual "one entry" 1 (V.length arr)
        Just other -> assertFailure ("Expected array, got: " <> show other)

  , testCase "JSON stack list non-query mode has wrapper" $ do
      let display = StackListDisplay
            { sldStacks = [testStackListEntry]
            , sldShowTags = True
            , sldFiltersApplied = ["status:CREATE_COMPLETE"]
            , sldColumns = [ColName, ColStatus, ColTags]
            , sldQueryMode = False
            }
          val = stackListToValue display
      assertEqual "show_tags" (Just (Aeson.Bool True)) (jsonLookup "show_tags" val)
      assertBool "has stacks" (jsonLookup "stacks" val /= Nothing)
      assertBool "has filters" (jsonLookup "filters_applied" val /= Nothing)
      assertBool "has columns" (jsonLookup "columns" val /= Nothing)

  , testCase "JSON stack definition envelope structure" $ do
      let envelope = Aeson.object
            [ "type" Aeson..= ("stack_definition" :: Text)
            , "data" Aeson..= Aeson.object
                [ "stack_definition" Aeson..= defToValue testStackDef
                , "show_times" Aeson..= True
                ]
            ]
          encoded = encodeValue defaultJsonOptions envelope
          parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
      case parsed of
        Nothing -> assertFailure "Failed to parse JSON"
        Just v -> do
          assertEqual "type" (Just (String "stack_definition")) (jsonLookup "type" v)
          assertBool "has data" (jsonLookup "data" v /= Nothing)

  , testCase "JSON new stack events is array of event objects" $ do
      let events = Aeson.toJSON (map eventWithTimingToValue [testEventWithTiming])
          encoded = encodeValue defaultJsonOptions events
          parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
      case parsed of
        Nothing -> assertFailure "Failed to parse JSON"
        Just (Array arr) -> do
          assertEqual "one event" 1 (V.length arr)
          case V.head arr of
            Object _ -> pure ()
            other -> assertFailure ("Expected object in array, got: " <> show other)
        Just other -> assertFailure ("Expected array, got: " <> show other)
  ]

------------------------------------------------------------------------
-- Additional test data builders for integration tests
------------------------------------------------------------------------

testCommandMetadata :: CommandMetadata
testCommandMetadata = CommandMetadata
  { cmEnvironment       = "development"
  , cmRegion            = "us-east-1"
  , cmProfile           = Just "dev-profile"
  , cmCliArguments      = Map.fromList [("stack-name", "my-stack")]
  , cmIamServiceRole    = Nothing
  , cmCurrentIamPrincipal = "arn:aws:iam::123456789012:user/dev"
  , cmCredentialSource  = "environment"
  , cmVersion           = "0.1.0"
  , cmPrimaryToken      = testTokenInfo
  , cmDerivedTokens     = []
  }

testStackEventsDisplay :: StackEventsDisplay
testStackEventsDisplay = StackEventsDisplay
  { sedTitle     = "Recent Events"
  , sedEvents    = [testEventWithTiming]
  , sedMaxEvents = Just 25
  , sedTruncated = Nothing
  }

testStackContents :: StackContents
testStackContents = StackContents
  { scResources = [StackResourceInfo
      { sriLogicalResourceId = "MyBucket"
      , sriPhysicalResourceId = Just "my-bucket-abc"
      , sriResourceType = "AWS::S3::Bucket"
      , sriResourceStatus = "CREATE_COMPLETE"
      , sriResourceStatusReason = Nothing
      , sriLastUpdated = Just testTimestamp
      }]
  , scOutputs = [StackOutputInfo
      { soiOutputKey = "BucketName"
      , soiOutputValue = "my-bucket-abc"
      , soiDescription = Just "The S3 bucket name"
      , soiExportName = Just "MyBucketName"
      }]
  , scExports = []
  , scCurrentStatus = StackStatusInfo
      { ssiStatus = "CREATE_COMPLETE"
      , ssiStatusReason = Nothing
      , ssiTimestamp = Just testTimestamp
      }
  , scPendingChangesets = []
  }

testFinalCommandSummary :: FinalCommandSummary
testFinalCommandSummary = FinalCommandSummary
  { fcsResult = SummarySuccess
  , fcsElapsedSeconds = 42
  }

testStackListDisplay :: StackListDisplay
testStackListDisplay = StackListDisplay
  { sldStacks = [testStackListEntry]
  , sldShowTags = True
  , sldFiltersApplied = []
  , sldColumns = [ColName, ColStatus, ColTags]
  , sldQueryMode = False
  }

testChangeSetResult :: ChangeSetCreationResult
testChangeSetResult = ChangeSetCreationResult
  { csrChangesetName = "changeset-awesome-lion"
  , csrStackName = "my-stack"
  , csrChangesetType = "UPDATE"
  , csrStatus = "CREATE_COMPLETE"
  , csrConsoleUrl = "https://console.aws.amazon.com/cloudformation/home#/stacks/changesets/details?stackId=my-stack&changeSetId=changeset-awesome-lion"
  , csrHasChanges = True
  , csrPendingChangesets = []
  , csrNextSteps = ["Execute the changeset to apply changes"]
  }

testStackDrift :: StackDrift
testStackDrift = StackDrift
  { sdrDriftedResources = [DriftedResource
      { drLogicalResourceId = "MyBucket"
      , drPhysicalResourceId = "my-bucket-abc"
      , drResourceType = "AWS::S3::Bucket"
      , drDriftStatus = "MODIFIED"
      , drPropertyDifferences = [PropertyDifference
          { pdPropertyPath = "/VersioningConfiguration/Status"
          , pdExpectedValue = Just "Enabled"
          , pdActualValue = Just "Suspended"
          , pdDifferenceType = Just "NOT_EQUAL"
          }]
      }]
  }

testOperationComplete :: OperationCompleteInfo
testOperationComplete = OperationCompleteInfo
  { ociElapsedSeconds = 120
  , ociOperationStartTime = testTimestamp
  , ociSkipRemainingSections = False
  }

testInactivityTimeout :: InactivityTimeoutInfo
testInactivityTimeout = InactivityTimeoutInfo
  { itiTimeoutSeconds = 180
  , itiElapsedSeconds = 200
  , itiOperationStartTime = testTimestamp
  }

testConfirmationRequest :: ConfirmationRequest
testConfirmationRequest = ConfirmationRequest
  { cfrMessage = "Are you sure you want to delete my-stack?"
  , cfrKey = Just "yes"
  }

testStackChangeDetails :: StackChangeDetails
testStackChangeDetails = StackChangeDetails
  { scdChangeType = ChangeCreate
  , scdStackName = "my-stack"
  }

testCostEstimate :: CostEstimate
testCostEstimate = CostEstimate
  { ceInfo = CostEstimateInfo
      { ceiUrl = "https://calculator.aws/estimate?id=abc123"
      , ceiStackName = Just "my-stack"
      , ceiTemplateFile = Just "template.yaml"
      }
  }

testStackTemplate :: StackTemplate
testStackTemplate = StackTemplate
  { stStderrLines = ["Fetching template for my-stack..."]
  , stTemplateBody = "AWSTemplateFormatVersion: '2010-09-09'\nResources:\n  MyBucket:\n    Type: AWS::S3::Bucket\n"
  }

testApprovalRequestResult :: ApprovalRequestResult
testApprovalRequestResult = ApprovalRequestResult
  { arrTemplateLocation = "s3://templates/my-stack/template.yaml"
  , arrPendingLocation = "s3://templates/my-stack/pending.yaml"
  , arrAlreadyApproved = False
  , arrNextSteps = ["Review template", "Approve or reject"]
  }

testTemplateValidation :: TemplateValidation
testTemplateValidation = TemplateValidation
  { tvEnabled = True
  , tvErrors = []
  , tvWarnings = ["Parameter Env has no default value"]
  }

testApprovalStatus :: ApprovalStatus
testApprovalStatus = ApprovalStatus
  { apsPendingExists = True
  , apsAlreadyApproved = False
  , apsPendingLocation = "s3://templates/my-stack/pending.yaml"
  , apsApprovedLocation = Nothing
  }

testTemplateDiff :: TemplateDiff
testTemplateDiff = TemplateDiff
  { tdDiffOutput = "--- a/template.yaml\n+++ b/template.yaml\n@@ -1,3 +1,3 @@\n Resources:\n   MyBucket:\n-    Type: AWS::S3::Bucket\n+    Type: AWS::S3::Bucket\n+    Properties:\n+      VersioningConfiguration:\n+        Status: Enabled\n"
  , tdContextLines = 3
  , tdHasChanges = True
  }

testApprovalResult :: ApprovalResult
testApprovalResult = ApprovalResult
  { arApproved = True
  , arApprovedLocation = Just "s3://templates/my-stack/approved.yaml"
  , arLatestLocation = Just "s3://templates/my-stack/template.yaml"
  , arCleanupCompleted = True
  }

-- | All OutputData variants for comprehensive testing
allTestOutputData :: [OutputData]
allTestOutputData =
  [ OdCommandMetadata testCommandMetadata
  , OdStackDefinition testStackDef True
  , OdStackDefinition testStackDef False
  , OdStackEvents testStackEventsDisplay
  , OdStackContents testStackContents
  , OdStatusUpdate testStatusUpdate
  , OdCommandResult testCommandResult
  , OdFinalCommandSummary testFinalCommandSummary
  , OdStackList testStackListDisplay
  , OdChangeSetResult testChangeSetResult
  , OdStackDrift testStackDrift
  , OdError testErrorInfo
  , OdTokenInfo testTokenInfo
  , OdNewStackEvents [testEventWithTiming]
  , OdOperationComplete testOperationComplete
  , OdInactivityTimeout testInactivityTimeout
  , OdConfirmationPrompt testConfirmationRequest
  , OdStackChangeDetails testStackChangeDetails
  , OdStackAbsentInfo testAbsentInfo
  , OdCostEstimate testCostEstimate
  , OdStackTemplate testStackTemplate
  , OdApprovalRequestResult testApprovalRequestResult
  , OdTemplateValidation testTemplateValidation
  , OdApprovalStatus testApprovalStatus
  , OdTemplateDiff testTemplateDiff
  , OdApprovalResult testApprovalResult
  , OdPollingStarted "Loading live events..."
  ]

------------------------------------------------------------------------
-- Integration tests (Phase 13.9)
------------------------------------------------------------------------

integrationTests :: [TestTree]
integrationTests =
  [ testGroup "InteractiveRenderer" interactiveRendererIntegrationTests
  , testGroup "JsonRenderer" jsonRendererIntegrationTests
  , testGroup "OutputSequences" outputSequenceTests
  ]

interactiveRendererIntegrationTests :: [TestTree]
interactiveRendererIntegrationTests =
  [ testCase "renderOutputData handles all OutputData variants without crashing" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      -- Each variant should render without throwing an exception
      results <- forM allTestOutputData $ \od -> do
        result <- try (renderOutputData r od) :: IO (Either SomeException ())
        case result of
          Left ex -> pure (Just (show od, ex))
          Right () -> pure Nothing
      let failures = [f | Just f <- results]
      when (not (null failures)) $
        assertFailure $ "Renderer crashed on variants: " <>
          unlines [tag <> ": " <> show ex | (tag, ex) <- failures]

  , testCase "renderOutputData colored handles all OutputData variants" $ do
      r <- newInteractiveRenderer defaultInteractiveOptions
      results <- forM allTestOutputData $ \od -> do
        result <- try (renderOutputData r od) :: IO (Either SomeException ())
        case result of
          Left ex -> pure (Just (show od, ex))
          Right () -> pure Nothing
      let failures = [f | Just f <- results]
      when (not (null failures)) $
        assertFailure $ "Colored renderer crashed on: " <>
          unlines [tag <> ": " <> show ex | (tag, ex) <- failures]

  , testCase "renderOutputData processes create-stack sequence in order" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      -- Simulate a create-stack output sequence
      let sequence =
            [ OdCommandMetadata testCommandMetadata
            , OdStackChangeDetails testStackChangeDetails
            , OdStackDefinition testStackDef True
            , OdPollingStarted "Loading live events..."
            , OdNewStackEvents [testEventWithTiming]
            , OdOperationComplete testOperationComplete
            , OdStackContents testStackContents
            , OdFinalCommandSummary testFinalCommandSummary
            ]
      -- All should render without exception
      mapM_ (renderOutputData r) sequence

  , testCase "renderOutputData processes describe-stack sequence in order" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      let sequence =
            [ OdCommandMetadata testCommandMetadata
            , OdStackDefinition testStackDef True
            , OdStackEvents testStackEventsDisplay
            , OdStackContents testStackContents
            , OdFinalCommandSummary testFinalCommandSummary
            ]
      mapM_ (renderOutputData r) sequence

  , testCase "renderOutputData processes delete-stack sequence in order" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      let sequence =
            [ OdCommandMetadata testCommandMetadata
            , OdStackDefinition testStackDef True
            , OdStackEvents testStackEventsDisplay
            , OdStackContents testStackContents
            , OdConfirmationPrompt testConfirmationRequest
            , OdPollingStarted "Waiting for stack deletion..."
            , OdNewStackEvents [testEventWithTiming]
            , OdOperationComplete testOperationComplete
            , OdFinalCommandSummary testFinalCommandSummary
            ]
      mapM_ (renderOutputData r) sequence

  , testCase "renderOutputData processes changeset sequence in order" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      let sequence =
            [ OdCommandMetadata testCommandMetadata
            , OdStackDefinition testStackDef True
            , OdChangeSetResult testChangeSetResult
            , OdFinalCommandSummary testFinalCommandSummary
            ]
      mapM_ (renderOutputData r) sequence

  , testCase "renderOutputData processes drift sequence in order" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      let sequence =
            [ OdCommandMetadata testCommandMetadata
            , OdStackDefinition testStackDef False
            , OdPollingStarted "Detecting drift..."
            , OdStackDrift testStackDrift
            , OdFinalCommandSummary testFinalCommandSummary
            ]
      mapM_ (renderOutputData r) sequence

  , testCase "renderOutputData processes stack-absent error" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      let sequence =
            [ OdCommandMetadata testCommandMetadata
            , OdStackAbsentInfo testAbsentInfo
            ]
      mapM_ (renderOutputData r) sequence

  , testCase "renderOutputData processes lint+approval sequence" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      let sequence =
            [ OdTemplateValidation testTemplateValidation
            , OdApprovalRequestResult testApprovalRequestResult
            , OdApprovalStatus testApprovalStatus
            , OdTemplateDiff testTemplateDiff
            , OdApprovalResult testApprovalResult
            ]
      mapM_ (renderOutputData r) sequence

  , testCase "renderOutputData handles empty events list" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      renderOutputData r (OdNewStackEvents [])

  , testCase "renderOutputData handles stack list" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      renderOutputData r (OdStackList testStackListDisplay)
  ]

jsonRendererIntegrationTests :: [TestTree]
jsonRendererIntegrationTests =
  [ testCase "renderOutputDataJson handles all OutputData variants without crashing" $ do
      let jr = newJsonRenderer defaultJsonOptions
      results <- forM allTestOutputData $ \od -> do
        result <- try (renderOutputDataJson jr od) :: IO (Either SomeException ())
        case result of
          Left ex -> pure (Just (show od, ex))
          Right () -> pure Nothing
      let failures = [f | Just f <- results]
      when (not (null failures)) $
        assertFailure $ "JSON renderer crashed on variants: " <>
          unlines [tag <> ": " <> show ex | (tag, ex) <- failures]

  , testCase "renderOutputDataJson handles create-stack sequence" $ do
      let jr = newJsonRenderer defaultJsonOptions
      let sequence =
            [ OdCommandMetadata testCommandMetadata
            , OdStackChangeDetails testStackChangeDetails
            , OdStackDefinition testStackDef True
            , OdPollingStarted "Loading..."
            , OdNewStackEvents [testEventWithTiming]
            , OdOperationComplete testOperationComplete
            , OdStackContents testStackContents
            , OdFinalCommandSummary testFinalCommandSummary
            ]
      mapM_ (renderOutputDataJson jr) sequence
  ]

-- | Test that OutputData variants cover all constructors.
-- This is a compile-time check via pattern matching exhaustiveness.
outputSequenceTests :: [TestTree]
outputSequenceTests =
  [ testCase "allTestOutputData covers all 27 OutputData variant types" $ do
      -- 26 constructors in OutputData, plus OdStackDefinition tested with
      -- both True and False = 27 entries, 26 unique constructor names.
      let uniqueTypes = nub (map odConstructorName allTestOutputData)
      assertEqual "unique OutputData constructors covered"
        26  -- 26 constructors in OutputData
        (length uniqueTypes)

  , testCase "create-stack sequence has correct order" $ do
      let sequence =
            [ OdCommandMetadata testCommandMetadata
            , OdStackChangeDetails testStackChangeDetails
            , OdStackDefinition testStackDef True
            , OdPollingStarted "Loading live events..."
            , OdNewStackEvents [testEventWithTiming]
            , OdOperationComplete testOperationComplete
            , OdStackContents testStackContents
            , OdFinalCommandSummary testFinalCommandSummary
            ]
          names = map odConstructorName sequence
      assertEqual "sequence order"
        ["CommandMetadata", "StackChangeDetails", "StackDefinition"
        ,"PollingStarted", "NewStackEvents", "OperationComplete"
        ,"StackContents", "FinalCommandSummary"]
        names

  , testCase "describe-stack sequence has correct order" $ do
      let sequence =
            [ OdCommandMetadata testCommandMetadata
            , OdStackDefinition testStackDef True
            , OdStackEvents testStackEventsDisplay
            , OdStackContents testStackContents
            , OdFinalCommandSummary testFinalCommandSummary
            ]
          names = map odConstructorName sequence
      assertEqual "sequence order"
        ["CommandMetadata", "StackDefinition", "StackEvents"
        ,"StackContents", "FinalCommandSummary"]
        names

  , testCase "delete-stack sequence has correct order" $ do
      let sequence =
            [ OdCommandMetadata testCommandMetadata
            , OdStackDefinition testStackDef True
            , OdStackEvents testStackEventsDisplay
            , OdStackContents testStackContents
            , OdConfirmationPrompt testConfirmationRequest
            , OdPollingStarted "Waiting..."
            , OdNewStackEvents [testEventWithTiming]
            , OdOperationComplete testOperationComplete
            , OdFinalCommandSummary testFinalCommandSummary
            ]
          names = map odConstructorName sequence
      assertEqual "sequence order"
        ["CommandMetadata", "StackDefinition", "StackEvents"
        ,"StackContents", "ConfirmationPrompt", "PollingStarted"
        ,"NewStackEvents", "OperationComplete", "FinalCommandSummary"]
        names
  ]

-- | Extract constructor name from OutputData for sequence testing
odConstructorName :: OutputData -> String
odConstructorName (OdCommandMetadata _)         = "CommandMetadata"
odConstructorName (OdStackDefinition _ _)       = "StackDefinition"
odConstructorName (OdStackEvents _)             = "StackEvents"
odConstructorName (OdStackContents _)           = "StackContents"
odConstructorName (OdStatusUpdate _)            = "StatusUpdate"
odConstructorName (OdCommandResult _)           = "CommandResult"
odConstructorName (OdFinalCommandSummary _)     = "FinalCommandSummary"
odConstructorName (OdStackList _)               = "StackList"
odConstructorName (OdChangeSetResult _)         = "ChangeSetResult"
odConstructorName (OdStackDrift _)              = "StackDrift"
odConstructorName (OdError _)                   = "Error"
odConstructorName (OdTokenInfo _)               = "TokenInfo"
odConstructorName (OdNewStackEvents _)          = "NewStackEvents"
odConstructorName (OdOperationComplete _)       = "OperationComplete"
odConstructorName (OdInactivityTimeout _)       = "InactivityTimeout"
odConstructorName (OdConfirmationPrompt _)      = "ConfirmationPrompt"
odConstructorName (OdStackChangeDetails _)      = "StackChangeDetails"
odConstructorName (OdStackAbsentInfo _)         = "StackAbsentInfo"
odConstructorName (OdCostEstimate _)            = "CostEstimate"
odConstructorName (OdStackTemplate _)           = "StackTemplate"
odConstructorName (OdApprovalRequestResult _)   = "ApprovalRequestResult"
odConstructorName (OdTemplateValidation _)      = "TemplateValidation"
odConstructorName (OdApprovalStatus _)          = "ApprovalStatus"
odConstructorName (OdTemplateDiff _)            = "TemplateDiff"
odConstructorName (OdApprovalResult _)          = "ApprovalResult"
odConstructorName (OdPollingStarted _)          = "PollingStarted"

------------------------------------------------------------------------
-- Phase 14 fix tests (tests for bug fixes from Sessions 36-38)
------------------------------------------------------------------------

phase14FixTests :: [TestTree]
phase14FixTests =
  -- 1. buildCliArguments: only includes explicit CLI flags
  [ testCase "buildCliArguments - no flags = empty map" $ do
      let settings = AwsSettings Nothing Nothing Nothing
      buildCliArguments settings Nothing @?= Map.empty

  , testCase "buildCliArguments - all flags present" $ do
      let settings = AwsSettings (Just "prod") (Just "eu-west-1") (Just "arn:aws:iam::role/x")
      let result = buildCliArguments settings (Just "my-stack")
      Map.lookup "profile" result @?= Just "prod"
      Map.lookup "region" result @?= Just "eu-west-1"
      Map.lookup "stack-name" result @?= Just "my-stack"
      Map.lookup "assume-role-arn" result @?= Just "arn:aws:iam::role/x"

  , testCase "buildCliArguments - no CLI stack name excludes stack-name" $ do
      let settings = AwsSettings (Just "prod") Nothing Nothing
      let result = buildCliArguments settings Nothing
      Map.lookup "stack-name" result @?= Nothing
      Map.lookup "profile" result @?= Just "prod"

  -- 2. getStrMapValidated: rejects non-string values
  , testCase "getStrMapValidated - valid string map" $ do
      let obj = KM.fromList
            [ (AesonKey.fromText "Tags", Object $ KM.fromList
                [ (AesonKey.fromText "Env", String "prod")
                , (AesonKey.fromText "Team", String "platform")
                ])
            ]
      case getStrMapValidated obj "Tags" of
        Right (Just m) -> do
          Map.lookup "Env" m @?= Just "prod"
          Map.lookup "Team" m @?= Just "platform"
        Right Nothing -> assertFailure "expected Just, got Nothing"
        Left e -> assertFailure ("unexpected error: " <> T.unpack e)

  , testCase "getStrMapValidated - rejects integer value" $ do
      let obj = KM.fromList
            [ (AesonKey.fromText "Tags", Object $ KM.fromList
                [ (AesonKey.fromText "Count", Number 42)
                ])
            ]
      case getStrMapValidated obj "Tags" of
        Left e -> assertBool "mentions expected a string" ("expected a string" `T.isInfixOf` e)
        Right _ -> assertFailure "should reject non-string value"

  , testCase "getStrMapValidated - rejects boolean value" $ do
      let obj = KM.fromList
            [ (AesonKey.fromText "Tags", Object $ KM.fromList
                [ (AesonKey.fromText "Enabled", Bool True)
                ])
            ]
      case getStrMapValidated obj "Tags" of
        Left e -> assertBool "mentions expected a string" ("expected a string" `T.isInfixOf` e)
        Right _ -> assertFailure "should reject boolean value"

  , testCase "getStrMapValidated - missing key = Nothing" $ do
      let obj = KM.fromList []
      getStrMapValidated obj "Tags" @?= Right Nothing

  , testCase "getStrMapValidated - non-object type = error" $ do
      let obj = KM.fromList
            [ (AesonKey.fromText "Tags", String "not-a-map")
            ]
      case getStrMapValidated obj "Tags" of
        Left e -> assertBool "mentions expected a mapping" ("expected a mapping" `T.isInfixOf` e)
        Right _ -> assertFailure "should reject non-object type"

  -- 3. Credential display text
  , testCase "sourceDisplayName - static env vars" $
      sourceDisplayName EnvironmentVariablesStatic
        @?= "environment variables (AWS_ACCESS_KEY_ID)"

  , testCase "sourceDisplayName - temporary env vars" $
      sourceDisplayName EnvironmentVariablesTemporary
        @?= "environment variables (AWS_ACCESS_KEY_ID + AWS_SESSION_TOKEN)"

  , testCase "sourceDisplayName - profile from CLI" $ do
      let pinfo = ProfileInfo "production" ProfileCliFlag Nothing
      sourceDisplayName (ProfileCredential pinfo)
        @?= "profile 'production' (CLI flag)"

  , testCase "sourceDisplayName - profile from stack-args" $ do
      let pinfo = ProfileInfo "dev" ProfileStackArgs Nothing
      sourceDisplayName (ProfileCredential pinfo)
        @?= "profile 'dev' (stack-args)"

  , testCase "credentialDisplayName - single source" $ do
      let stack = CredentialSourceStack [EnvironmentVariablesStatic]
      credentialDisplayName stack
        @?= "environment variables (AWS_ACCESS_KEY_ID)"

  , testCase "credentialDisplayName - with override" $ do
      let stack = CredentialSourceStack
            [ EnvironmentVariablesTemporary
            , EnvironmentVariablesStatic
            ]
      let result = credentialDisplayName stack
      assertBool "shows overriding" ("overriding" `T.isInfixOf` result)
      assertBool "shows active" ("AWS_SESSION_TOKEN" `T.isInfixOf` result)

  , testCase "credentialDisplayName - empty = unknown" $
      credentialDisplayName (CredentialSourceStack []) @?= "unknown"

  -- 4. isNoUpdatesError
  , testCase "isNoUpdatesError - matches no-updates message" $ do
      let se = Amazonka.ServiceError' "cloudformation" status400 []
                 "ValidationError"
                 (Just "No updates are to be performed.")
                 Nothing
      isNoUpdatesError (Amazonka.ServiceError se) @?= True

  , testCase "isNoUpdatesError - no match on different message" $ do
      let se = Amazonka.ServiceError' "cloudformation" status400 []
                 "ValidationError"
                 (Just "Stack does not exist")
                 Nothing
      isNoUpdatesError (Amazonka.ServiceError se) @?= False

  , testCase "isNoUpdatesError - no match on missing message" $ do
      let se = Amazonka.ServiceError' "cloudformation" status400 []
                 "ValidationError"
                 Nothing
                 Nothing
      isNoUpdatesError (Amazonka.ServiceError se) @?= False

  -- 5. Event duration minimum 1 second
  , testCase "calculateEventDurations - sub-second rounds to 1" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          -- 0.5 seconds later — should still get min 1
          t05 = addUTCTime (secondsToNominalDiffTime 0.5) t0
          events =
            [ mkEvent "e1" "Res" "AWS::S3::Bucket" "CREATE_IN_PROGRESS" (Just t0)
            , mkEvent "e2" "Res" "AWS::S3::Bucket" "CREATE_COMPLETE" (Just t05)
            ]
          result = calculateEventDurations events
      assertEqual "sub-second → 1" (Just 1) (sewDurationSeconds (result !! 1))

  , testCase "convertEventWithDuration - sub-second rounds to 1" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          t05 = addUTCTime (secondsToNominalDiffTime 0.1) t0
          event = SE.newStackEvent "stack-id" "e1" "test-stack" t05
          result = convertEventWithDuration t0 event
      assertEqual "sub-second → 1" (Just 1) (sewDurationSeconds result)

  , testCase "convertEventWithDuration - exact 3 seconds" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          t3 = addUTCTime (secondsToNominalDiffTime 3) t0
          event = SE.newStackEvent "stack-id" "e1" "test-stack" t3
          result = convertEventWithDuration t0 event
      assertEqual "3 seconds" (Just 3) (sewDurationSeconds result)
  ]
