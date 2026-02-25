module Test.FixtureTest (buildFixtureTests) where

import Control.Monad (forM, when)
import qualified Data.ByteString.Lazy as BL
import Data.List (sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, listDirectory)
import System.FilePath ((</>), takeBaseName, takeExtension)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Yaml.Detection (detectYamlSpec, shouldUseYaml11Compatibility)
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Engine (preprocessYaml, preprocessYaml11, PreprocessResult(..), PreprocessError(..))
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.Parser (parseYaml)

fixtureDir :: FilePath
fixtureDir = "test-fixtures"

inputDir :: FilePath
inputDir = fixtureDir </> "example-templates"

expectedDir :: FilePath
expectedDir = fixtureDir </> "expected-outputs"

buildFixtureTests :: IO [TestTree]
buildFixtureTests = do
  topLevel <- collectFixtureTests inputDir expectedDir ""
  let subName = "yaml-iidy-syntax"
  subLevel <- collectFixtureTests
    (inputDir </> subName)
    (expectedDir </> subName)
    (subName <> "/")
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
  rawInput <- BL.readFile inPath
  expectedRaw <- TIO.readFile outPath
  let expected = T.stripEnd expectedRaw

  let parseResult = parseYaml rawInput (T.pack inPath)
  ast <- case parseResult of
    Left pe -> assertFailure $
      "Parse error in " <> inPath <> ": " <> show pe
    Right a -> return a

  let source = TE.decodeUtf8 (BL.toStrict rawInput)
      useYaml11 = shouldUseYaml11Compatibility (detectYamlSpec source)
      preprocess = if useYaml11 then preprocessYaml11 else preprocessYaml
  preprocessResult <- preprocess loadFileImport ast (T.pack inPath)
  pr <- case preprocessResult of
    Left err -> assertFailure $
      "Preprocess error in " <> inPath <> ": " <> describePreprocessError err
    Right r -> return r

  let emitted = T.stripEnd (emitYaml (prValue pr))

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
