module Test.ErrorFixtureTest (buildErrorTests) where

import qualified Data.ByteString.Lazy as BL
import Data.List (sort)
import qualified Data.Text as T
import System.Directory (listDirectory)
import System.FilePath ((</>), takeBaseName, takeExtension)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Yaml.Engine (preprocessYaml)
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.Parser (parseYaml)

errorFixtureDir :: FilePath
errorFixtureDir = "test-fixtures/example-templates/errors"

buildErrorTests :: IO [TestTree]
buildErrorTests = do
  files <- sort <$> listDirectory errorFixtureDir
  let yamlFiles = filter (\f -> takeExtension f == ".yaml" || takeExtension f == ".yml") files
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
    Left _pe -> pure ()
    Right ast -> do
      preprocessResult <- preprocessYaml loadFileImport ast (T.pack inPath)
      case preprocessResult of
        Left _err -> pure ()
        Right _r -> assertFailure $
          "Expected error for " <> inPath <> " but got success"
