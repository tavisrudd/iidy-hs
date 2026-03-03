module Main (main) where

import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.FilePath ((</>))
import Test.Tasty.Bench

import Iidy.Yaml.Ast (YamlAst)
import Iidy.Yaml.Detection (detectYamlSpec, shouldUseYaml11Compatibility)
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Engine (preprocessYaml, preprocessYaml11, PreprocessResult(..), PreprocessError(..))
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.OValue (OValue)
import Iidy.Yaml.Parser (parseYaml)

------------------------------------------------------------------------
-- Fixture paths
------------------------------------------------------------------------

fixtureDir :: FilePath
fixtureDir = "test-fixtures" </> "example-templates"

basicFixture :: FilePath
basicFixture = fixtureDir </> "basic-test.yaml"

advancedFixture :: FilePath
advancedFixture = fixtureDir </> "advanced-cloudformation.yaml"

simpleFixture :: FilePath
simpleFixture = fixtureDir </> "simple-cloudformation.yaml"

defsFixture :: FilePath
defsFixture = fixtureDir </> "yaml-iidy-syntax" </> "defs-basic-cross-reference.yaml"

handlebarsFixture :: FilePath
handlebarsFixture = fixtureDir </> "handlebars-in-tags.yaml"

mapFixture :: FilePath
mapFixture = fixtureDir </> "yaml-iidy-syntax" </> "map.yaml"

------------------------------------------------------------------------
-- Synthetic data generation
------------------------------------------------------------------------

-- | Generate a large YAML mapping with N key-value pairs.
generateLargeYaml :: Int -> BL.ByteString
generateLargeYaml n =
  let pairs = map (\i -> "key_" <> show i <> ": value_" <> show i) [1..n]
  in BL.fromStrict $ TE.encodeUtf8 $ T.pack $ unlines pairs

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Load a fixture file and return its raw bytes.
loadFixture :: FilePath -> IO BL.ByteString
loadFixture = BL.readFile

-- | Run the full preprocess pipeline on raw YAML input.
-- Returns the emitted YAML text.
runPipeline :: BL.ByteString -> FilePath -> IO Text
runPipeline rawInput path = do
  let uri = T.pack path
  ast <- case parseYaml rawInput uri of
    Left pe -> error $ "Parse error: " <> show pe
    Right a -> pure a
  let source = TE.decodeUtf8 (BL.toStrict rawInput)
      useYaml11 = shouldUseYaml11Compatibility (detectYamlSpec source)
      preprocess = if useYaml11 then preprocessYaml11 else preprocessYaml
  result <- preprocess loadFileImport ast uri
  case result of
    Left err -> error $ "Preprocess error: " <> describeError err
    Right pr -> pure $ emitYaml (prValue pr)

-- | Describe a PreprocessError for error messages.
describeError :: PreprocessError -> String
describeError = \case
  PeResolveError e -> "resolve: " <> show e
  PeImportError e  -> "import: " <> show e
  PeHandlebarsError e -> "handlebars: " <> show e
  PeCycleError t   -> "cycle: " <> T.unpack t

-- | Pre-process an AST to get an OValue for emission benchmarks.
runPreprocess :: YamlAst -> FilePath -> IO OValue
runPreprocess ast path = do
  let uri = T.pack path
  result <- preprocessYaml loadFileImport ast uri
  case result of
    Left err -> error $ "Setup preprocess error: " <> describeError err
    Right pr -> pure (prValue pr)

------------------------------------------------------------------------
-- Main benchmark suite
------------------------------------------------------------------------

main :: IO ()
main = do
  -- Pre-load fixture data outside benchmark loops
  basicRaw      <- loadFixture basicFixture
  advancedRaw   <- loadFixture advancedFixture
  simpleRaw     <- loadFixture simpleFixture
  defsRaw       <- loadFixture defsFixture
  handlebarsRaw <- loadFixture handlebarsFixture
  mapRaw        <- loadFixture mapFixture

  let largeRaw = generateLargeYaml 1000

  -- Pre-parse fixtures for emission benchmarks
  let parseOrFail raw uri = case parseYaml raw uri of
        Left pe -> error $ "Setup parse error: " <> show pe
        Right a -> a

  let basicAst    = parseOrFail basicRaw (T.pack basicFixture)
      advancedAst = parseOrFail advancedRaw (T.pack advancedFixture)
      simpleAst   = parseOrFail simpleRaw (T.pack simpleFixture)

  -- Pre-run the pipeline for emission benchmarks (need OValues)
  basicOVal    <- runPreprocess basicAst basicFixture
  advancedOVal <- runPreprocess advancedAst advancedFixture
  simpleOVal   <- runPreprocess simpleAst simpleFixture

  defaultMain
    [ bgroup "parse"
      [ bench "basic (320B)"          $ whnf (parseYaml basicRaw)    (T.pack basicFixture)
      , bench "simple-cfn (3KB)"      $ whnf (parseYaml simpleRaw)   (T.pack simpleFixture)
      , bench "advanced-cfn (10KB)"   $ whnf (parseYaml advancedRaw) (T.pack advancedFixture)
      , bench "synthetic (1000 keys)" $ whnf (parseYaml largeRaw)    "<synthetic>"
      ]
    , bgroup "preprocess"
      [ bench "basic"        $ nfAppIO (runPipeline basicRaw)      basicFixture
      , bench "defs"         $ nfAppIO (runPipeline defsRaw)       defsFixture
      , bench "handlebars"   $ nfAppIO (runPipeline handlebarsRaw) handlebarsFixture
      , bench "map"          $ nfAppIO (runPipeline mapRaw)        mapFixture
      , bench "simple-cfn"   $ nfAppIO (runPipeline simpleRaw)     simpleFixture
      , bench "advanced-cfn" $ nfAppIO (runPipeline advancedRaw)   advancedFixture
      ]
    , bgroup "emit"
      [ bench "basic"        $ nf emitYaml basicOVal
      , bench "simple-cfn"   $ nf emitYaml simpleOVal
      , bench "advanced-cfn" $ nf emitYaml advancedOVal
      ]
    , bgroup "pipeline"
      [ bench "basic (parse+preprocess+emit)"
          $ nfAppIO (runPipeline basicRaw) basicFixture
      , bench "simple-cfn (parse+preprocess+emit)"
          $ nfAppIO (runPipeline simpleRaw) simpleFixture
      , bench "advanced-cfn (parse+preprocess+emit)"
          $ nfAppIO (runPipeline advancedRaw) advancedFixture
      ]
    ]
