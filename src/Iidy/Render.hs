module Iidy.Render
  ( runRender
  ) where

import qualified Data.Aeson.Encode.Pretty as Pretty
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import System.Directory (doesFileExist)
import System.IO (stderr)

import Iidy.Cli (RenderArgs(..), GlobalOpts(..))
import Iidy.Types (YamlSpec(..))
import Iidy.Yaml.Detection (detectYamlSpec, shouldUseYaml11Compatibility)
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Engine
  ( preprocessYaml
  , preprocessYaml11
  , PreprocessResult(..)
  )
import Iidy.Yaml.Errors.Conversion (formatPreprocessErrorEnhanced, formatParseErrorEnhanced)
import Iidy.Yaml.Imports.Loaders.File (dispatchLocalImport)
import Iidy.Yaml.JMESPath (applyJmesPath)
import Iidy.Yaml.OValue (OValue, toValue, fromValue)
import Iidy.Yaml.Parser (parseYaml, ParseError(..))

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- | Run the render command.  Returns 0 on success, 1 on error.
runRender :: RenderArgs -> GlobalOpts -> IO Int
runRender args gopts = do
  let templatePath = T.unpack (raTemplate args)

  -- Read input: "-" means stdin, otherwise treat as a file path.
  content <- if templatePath == "-"
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
                        YamlV11  -> True
                        YamlV12  -> False
                        YamlAuto -> shouldUseYaml11Compatibility (detectYamlSpec source)
          preprocess = if useYaml11 then preprocessYaml11 else preprocessYaml

      result <- preprocess dispatchLocalImport ast baseLocation
      case result of
        Left err -> do
          formatted <- formatPreprocessErrorEnhanced (goColor gopts) baseLocation source err
          TIO.hPutStr stderr formatted
          pure 1

        Right (PreprocessResult val _manifest) -> do
          -- Apply JMESPath query if provided
          let queryResult = case raQuery args of
                Nothing    -> Right val
                Just query -> case applyJmesPath query (toValue val) of
                  Left _err    -> Left query
                  Right filtered -> Right (fromValue filtered)
          case queryResult of
            Left query -> do
              TIO.hPutStrLn stderr ("Invalid JMESPath query: " <> query)
              pure 1
            Right outputVal -> do
              -- Validate format
              let fmt = T.toLower (raFormat args)
              case fmt of
                _ | fmt `notElem` ["json", "yaml", "yml", "yaml-cloudformation"] -> do
                  TIO.hPutStrLn stderr ("Unsupported format: " <> raFormat args <> ". Use 'yaml' or 'json'")
                  pure 1
                _ -> do
                  -- Format output
                  let rendered = case fmt of
                                   "json" -> formatJson outputVal
                                   _      -> emitYaml outputVal

                  -- Write output: "-" or "stdout" means stdout, otherwise write to file.
                  let outPath = T.unpack (raOutfile args)
                  if outPath == "-" || outPath == "stdout"
                    then do
                      TIO.putStrLn rendered
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
