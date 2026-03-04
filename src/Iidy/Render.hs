module Iidy.Render (
    runRender,
) where

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
import Iidy.Output.Types (OutputData (..))
import Iidy.Types (YamlSpec (..))
import Iidy.Yaml.Detection (detectYamlSpec, shouldUseYaml11Compatibility)
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Engine (
    PreprocessResult (..),
    preprocessYaml,
    preprocessYaml11,
 )
import Iidy.Yaml.Errors.Conversion (formatParseErrorEnhanced, formatPreprocessErrorEnhanced)
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..), mkFullDispatcher)
import Iidy.Yaml.Imports.Types (RemoteImports (..))
import Iidy.Yaml.JMESPath (applyJmesPath)
import Iidy.Yaml.OValue (OValue, fromValue, toValue)
import Iidy.Yaml.Parser (ParseError (..), parseYaml)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

{- | Run the render command.  Returns 0 on success, 1 on error.
The emitter callback is used to send stdout output through the output pipeline.
-}
runRender :: (OutputData -> IO ()) -> RenderArgs -> GlobalOpts -> IO Int
runRender emit args gopts = do
    let templatePath = T.unpack (raTemplate args)

    -- Read input: "-" means stdin, otherwise treat as a file path.
    content <-
        if templatePath == "-"
            then BL.getContents
            else BL.readFile templatePath

    let baseLocation = raTemplate args

    -- Parse YAML
    case parseYaml content baseLocation of
        Left (ParseError pos msg) -> do
            let source = TE.decodeUtf8 (BL.toStrict content)
            formatted <- formatParseErrorEnhanced (goColor gopts) baseLocation source pos msg
            TIO.hPutStr stderr formatted
            pure 1
        Right ast -> do
            -- Select YAML spec (1.1 vs 1.2)
            let source = TE.decodeUtf8 (BL.toStrict content)
                useYaml11 = case raYamlSpec args of
                    YamlV11 -> True
                    YamlV12 -> False
                    YamlAuto -> shouldUseYaml11Compatibility (detectYamlSpec source)
                preprocess = if useYaml11 then preprocessYaml11 else preprocessYaml

            let importCfg =
                    ImportConfig
                        { icAwsEnv = Nothing
                        , icRemoteImports = if goRemoteImports gopts then AllowRemoteImports else BlockRemoteImports
                        }
            result <- preprocess (mkFullDispatcher importCfg) ast baseLocation
            case result of
                Left err -> do
                    formatted <- formatPreprocessErrorEnhanced (goColor gopts) baseLocation source err
                    TIO.hPutStr stderr formatted
                    pure 1
                Right (PreprocessResult val _manifest) -> do
                    -- Apply JMESPath query if provided
                    let queryResult = case raQuery args of
                            Nothing -> Right val
                            Just query -> case applyJmesPath query (toValue val) of
                                Left _err -> Left query
                                Right filtered -> Right (fromValue filtered)
                    case queryResult of
                        Left query -> do
                            TIO.hPutStrLn stderr ("Invalid JMESPath query: " <> query)
                            pure 1
                        Right outputVal -> do
                            -- Format output (exhaustive match — no wildcard)
                            let rendered = case raFormat args of
                                    RenderJson -> formatJson outputVal
                                    RenderYaml -> emitYaml outputVal
                                    RenderCfnYaml -> emitYaml outputVal

                            -- Write output: "-" or "stdout" means stdout, otherwise write to file.
                            let outPath = T.unpack (raOutfile args)
                            if outPath == "-" || outPath == "stdout"
                                then do
                                    emit (OdRawOutput (rendered <> "\n"))
                                    pure 0
                                else do
                                    -- Check overwrite protection
                                    exists <- doesFileExist outPath
                                    if exists && not (raOverwrite args)
                                        then do
                                            TIO.hPutStrLn stderr ("Output file '" <> T.pack outPath <> "' exists. Use --overwrite to overwrite it.")
                                            pure 1
                                        else do
                                            TIO.writeFile outPath rendered
                                            TIO.hPutStrLn stderr ("Template rendered to: " <> T.pack outPath)
                                            pure 0

------------------------------------------------------------------------
-- Output formatting
------------------------------------------------------------------------

formatJson :: OValue -> Text
formatJson val =
    TL.toStrict (TLE.decodeUtf8 (Pretty.encodePretty (toValue val)))
