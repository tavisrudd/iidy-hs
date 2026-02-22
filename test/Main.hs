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

import Iidy.Aws.CredentialSource (AwsSettings(..))
import Iidy.Cfn.StackArgsLoader (loadStackArgs, LoadedStackArgs(..))
import Iidy.Cfn.Types (CfnOperation(..), StackArgs(..))
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Engine
  ( preprocessYaml
  , PreprocessResult(..)
  , PreprocessError(..)
  )
import Iidy.Yaml.Handlebars.Engine (interpolate, defaultHelpers)
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.JMESPath (applyJmesPath)
import Iidy.Yaml.OValue (OValue(..))
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
  defaultMain $ testGroup "iidy-hs"
    [ testGroup "Parser" parserTests
    , testGroup "JMESPath" jmespathTests
    , testGroup "Handlebars" handlebarsTests
    , testGroup "Emitter" emitterTests
    , testGroup "Fixtures" fixtureTests
    , testGroup "StackArgsLoader" stackArgsLoaderTests
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
  return (topLevel <> subLevel)

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
