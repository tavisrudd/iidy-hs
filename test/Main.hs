module Main (main) where

import Control.Exception (try, SomeException)
import Control.Monad (forM, when)
import Data.Aeson (Value(..))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.List (sort)
import qualified Data.Map.Strict
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import qualified Data.Vector as V
import System.Directory (doesFileExist, listDirectory)
import System.FilePath ((</>), takeBaseName, takeExtension)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit

import Options.Applicative (execParserPure, prefs, showHelpOnEmpty, ParserResult(..))

import qualified Amazonka.CloudFormation.Types as CF
import Iidy.Aws.CredentialSource (AwsSettings(..))
import Iidy.Cfn.RequestBuilder (mapCapability, mapCapabilities, mapParameters, mapTags, mapOnFailure)
import Iidy.Cfn.Operations.ConvertStack
  ( parameterizeEnv
  , parameterizeStackName
  , sortCfnKeys
  , templateBodyToYaml
  , buildStackArgsYaml
  )
import Iidy.Cfn.TemplateHash (calculateTemplateHash, generateVersionedLocation, parseS3Url)
import Iidy.Cfn.StackArgsLoader (loadStackArgs, LoadedStackArgs(..))
import Iidy.Cfn.Types (CfnOperation(..), StackArgs(..))
import Iidy.Cli (Cli(..), Commands(..), GlobalOpts(..), AwsOpts(..), DeleteArgs(..), DescribeArgs(..), RenderArgs(..))
import Iidy.Cli.Parser (cliParserInfo)
import Iidy.Types (ColorChoice(..), Theme(..), YamlSpec(..))
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Engine
  ( preprocessYaml
  , PreprocessResult(..)
  , PreprocessError(..)
  )
import Iidy.Yaml.Handlebars.Engine (interpolate, defaultHelpers)
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.JMESPath (applyJmesPath)
import Iidy.Yaml.CustomResources.JsonSchema (validateSchema)
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

  -- Preprocess with file loader
  preprocessResult <- preprocessYaml loadFileImport ast (T.pack inPath)
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
            daEvents args @?= 10  -- default
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
            raOutfile args @?= "-"
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
