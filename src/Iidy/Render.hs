module Iidy.Render
  ( runRender
  ) where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitWith, ExitCode(..))
import System.IO (stderr)

import Iidy.Cli (RenderArgs(..), GlobalOpts(..))
import Iidy.Types (YamlSpec(..))
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Engine
  ( preprocessYaml
  , preprocessYaml11
  , PreprocessResult(..)
  , PreprocessError(..)
  )
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.OValue (OValue, toValue)
import Iidy.Yaml.Parser (parseYaml, ParseError(..))

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- | Run the render command.  Returns 0 on success, 1 on error.
-- The function also calls 'exitWith' on failure so callers do not
-- need to inspect the return value when running as the main action.
runRender :: RenderArgs -> GlobalOpts -> IO Int
runRender args _gopts = do
  let templatePath = T.unpack (raTemplate args)

  -- Read input: "-" means stdin, otherwise treat as a file path.
  content <- if templatePath == "-"
    then BL.getContents
    else BL.readFile templatePath

  let baseLocation = raTemplate args

  -- Parse YAML
  case parseYaml content baseLocation of
    Left (ParseError _pos msg) -> do
      TIO.hPutStrLn stderr $ "Parse error: " <> msg
      exitWith (ExitFailure 1)

    Right ast -> do
      -- Select YAML spec (1.1 vs 1.2)
      let preprocess = case raYamlSpec args of
                         YamlV11  -> preprocessYaml11
                         _        -> preprocessYaml

      result <- preprocess loadFileImport ast baseLocation
      case result of
        Left err -> do
          TIO.hPutStrLn stderr $ "Preprocess error: " <> formatPreprocessError err
          exitWith (ExitFailure 1)

        Right (PreprocessResult val _manifest) -> do
          -- Format output
          let rendered = case T.toLower (raFormat args) of
                           "json" -> formatJson val
                           _      -> emitYaml val

          -- Write output: "-" means stdout, otherwise write to file.
          let outPath = T.unpack (raOutfile args)
          if outPath == "-"
            then TIO.putStrLn rendered
            else TIO.writeFile outPath rendered

          pure 0

------------------------------------------------------------------------
-- Output formatting
------------------------------------------------------------------------

formatJson :: OValue -> Text
formatJson val =
  T.pack
    . show
    . Aeson.encode
    $ toValue val

------------------------------------------------------------------------
-- Error formatting
------------------------------------------------------------------------

formatPreprocessError :: PreprocessError -> Text
formatPreprocessError = \case
  PeResolveError re    -> "Resolve error: "    <> T.pack (show re)
  PeImportError ie     -> "Import error: "     <> T.pack (show ie)
  PeHandlebarsError he -> "Handlebars error: " <> T.pack (show he)
  PeCycleError msg     -> "Import cycle: "     <> msg
