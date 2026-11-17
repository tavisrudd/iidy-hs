{- | Shared helpers for import trust tests (cards C14, C15): serve a
remote document from a stub, preprocess a template given as text, and
build an import policy from real command-line flags.
-}
module Test.ImportFixtures (
    stubDocLoader,
    preprocessText,
    flagPolicy,
    fileLoader,
) where

import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Options.Applicative (ParserResult (..), execParserPure, prefs)
import Test.Tasty.HUnit (assertFailure)

import Iidy.Cli (Cli (..), importPolicyFromOpts)
import Iidy.Cli.Parser (cliParserInfo)
import Iidy.Yaml.Engine (LoadImportFn, PreprocessError, PreprocessResult, preprocessYaml)
import Iidy.Yaml.Imports.ContentParsing (parseYamlContent)
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.Imports.Types (ImportBase (..), ImportData (..), ImportError (..), ImportPolicy, ImportType (..))
import Iidy.Yaml.Parser (parseYaml)

{- | Serve the YAML document @raw@ at @docLoc@, as the matching remote
loader would (the document's location becomes the base of its own
imports); send every other location to @fallback@, normally the real
dispatcher.
-}
stubDocLoader :: Text -> Text -> LoadImportFn -> LoadImportFn
stubDocLoader docLoc raw fallback loc base
    | loc == docLoc = pure $ case parseYamlContent raw of
        Left err -> Left (ImportError err)
        Right doc ->
            Right ImportData{idType = ImportHttp, idLocation = docLoc, idRawData = raw, idDoc = doc, idOrdered = Nothing}
    | otherwise = fallback loc base

-- | Parse @source@ as a template at @baseLoc@ and preprocess it.
preprocessText :: LoadImportFn -> Text -> Text -> IO (Either PreprocessError PreprocessResult)
preprocessText loader baseLoc source =
    case parseYaml (BL.fromStrict (TE.encodeUtf8 source)) baseLoc of
        Left err -> assertFailure ("template did not parse: " <> show err)
        Right ast -> preprocessYaml loader ast baseLoc

{- | The import policy the real command-line parser builds from
@--trust-import-source@ flags for these prefixes.
-}
flagPolicy :: [Text] -> IO ImportPolicy
flagPolicy prefixes =
    case execParserPure (prefs mempty) cliParserInfo args of
        Success cli -> pure (importPolicyFromOpts (cliGlobalOpts cli))
        _failure -> assertFailure ("flags did not parse: " <> show args)
  where
    args :: [String]
    args = concat [["--trust-import-source", T.unpack p] | p <- prefixes] <> ["render", "t.yaml"]

-- | Load every import as a local file relative to the requesting document.
fileLoader :: LoadImportFn
fileLoader loc base = loadFileImport loc (ibLocation base)
