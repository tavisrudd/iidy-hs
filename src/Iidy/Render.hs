module Iidy.Render (
    runRender,
) where

import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Data.Aeson.Encode.Pretty qualified as Pretty
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import System.Directory (doesFileExist)
import System.IO (stderr)

import Iidy.Cli (GlobalOpts (..), RenderArgs (..), RenderFormat (..))
import Iidy.Errors.JMESPath (formatJMESPathQueryError)
import Iidy.Output.Types (OutputData (..))
import Iidy.Types (YamlSpec (..))
import Iidy.Yaml.Ast (YamlAst)
import Iidy.Yaml.Detection (detectYamlSpec, shouldUseYaml11Compatibility)
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Engine (
    PreprocessError,
    PreprocessResult (..),
    preprocessYaml,
    preprocessYaml11,
 )
import Iidy.Yaml.Errors.Conversion (formatParseErrorEnhanced, formatPreprocessErrorEnhanced)
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..), mkFullDispatcher)
import Iidy.Yaml.Imports.Types (RemoteImports (..))
import Iidy.Yaml.JMESPath (JMESPathError, applyJmesPath)
import Iidy.Yaml.Location (Position)
import Iidy.Yaml.OValue (OValue, fromValue, toValue)
import Iidy.Yaml.Parser (ParseError (..), parseYaml)

------------------------------------------------------------------------
-- Error type
------------------------------------------------------------------------

data RenderError
    = ParseFailed !Position !Text
    | PreprocessFailed !PreprocessError
    | InvalidQuery !Text !JMESPathError
    | OutputFileExists !Text

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

{- | Run the render command.  Returns 0 on success, 1 on error.
The emitter callback is used to send stdout output through the output pipeline.
-}
runRender :: (OutputData -> IO ()) -> RenderArgs -> GlobalOpts -> IO Int
runRender emit args gopts = do
    (content, baseLocation) <- readTemplate args
    let source = TE.decodeUtf8 (BL.toStrict content)
        importCfg =
            ImportConfig
                { icAwsEnv = Nothing
                , icRemoteImports = if goRemoteImports gopts then AllowRemoteImports else BlockRemoteImports
                }
    result <- runExceptT $ do
        ast <- ExceptT . pure $ parseStep content baseLocation
        val <- ExceptT $ preprocessStep source importCfg ast
        outputVal <- ExceptT . pure $ queryStep val
        ExceptT $ writeStep outputVal
    either (reportError baseLocation source) pure result
  where
    parseStep :: BL.ByteString -> Text -> Either RenderError YamlAst
    parseStep content baseLocation =
        case parseYaml content baseLocation of
            Left (ParseError pos msg) -> Left (ParseFailed pos msg)
            Right ast -> Right ast

    preprocessStep :: Text -> ImportConfig -> YamlAst -> IO (Either RenderError OValue)
    preprocessStep source importCfg ast = do
        let useYaml11 = case raYamlSpec args of
                YamlV11 -> True
                YamlV12 -> False
                YamlAuto -> shouldUseYaml11Compatibility (detectYamlSpec source)
            preprocess = if useYaml11 then preprocessYaml11 else preprocessYaml
        result <- preprocess (mkFullDispatcher importCfg) ast (raTemplate args)
        pure $ case result of
            Left err -> Left (PreprocessFailed err)
            Right (PreprocessResult val _manifest) -> Right val

    queryStep :: OValue -> Either RenderError OValue
    queryStep val =
        case raQuery args of
            Nothing -> Right val
            Just query -> case applyJmesPath query (toValue val) of
                Left err -> Left (InvalidQuery query err)
                Right filt -> Right (fromValue filt)

    writeStep :: OValue -> IO (Either RenderError Int)
    writeStep outputVal = do
        let rendered = case raFormat args of
                RenderJson -> formatJson outputVal
                RenderYaml -> emitYaml outputVal
                RenderCfnYaml -> emitYaml outputVal
            outPath = raOutfile args
        if isStdoutTarget outPath
            then emit (OdRawOutput (rendered <> "\n")) >> pure (Right 0)
            else do
                exists <- doesFileExist (T.unpack outPath)
                if exists && not (raOverwrite args)
                    then pure (Left (OutputFileExists outPath))
                    else do
                        TIO.writeFile (T.unpack outPath) rendered
                        pure (Right 0)

    reportError :: Text -> Text -> RenderError -> IO Int
    reportError baseLocation source = \case
        ParseFailed pos msg -> do
            formatted <- formatParseErrorEnhanced (goColor gopts) baseLocation source pos msg
            TIO.hPutStr stderr formatted
            pure 1
        PreprocessFailed err -> do
            formatted <- formatPreprocessErrorEnhanced (goColor gopts) baseLocation source err
            TIO.hPutStr stderr formatted
            pure 1
        InvalidQuery query err -> do
            formatted <- formatJMESPathQueryError (goColor gopts) query err
            TIO.hPutStr stderr formatted
            pure 1
        OutputFileExists p ->
            TIO.hPutStrLn stderr ("Output file '" <> p <> "' exists. Use --overwrite to overwrite it.") >> pure 1

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

readTemplate :: RenderArgs -> IO (BL.ByteString, Text)
readTemplate args = do
    let path = raTemplate args
    content <- if path == "-" then BL.getContents else BL.readFile (T.unpack path)
    pure (content, path)

isStdoutTarget :: Text -> Bool
isStdoutTarget t = t == "-" || t == "stdout"

formatJson :: OValue -> Text
formatJson val =
    TL.toStrict (TLE.decodeUtf8 (Pretty.encodePretty (toValue val)))
