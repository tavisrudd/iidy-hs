module Main (main) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Iidy.Yaml.Engine (preprocessYaml, PreprocessResult(..), PreprocessError(..))
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.Parser (parseYaml, ParseError(..))

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["render", templatePath] -> renderCommand templatePath
    ("render":_) -> do
      hPutStrLn stderr "Usage: iidy-hs render <template-file>"
      exitFailure
    _ -> do
      hPutStrLn stderr "Usage: iidy-hs render <template-file>"
      exitFailure

renderCommand :: FilePath -> IO ()
renderCommand templatePath = do
  content <- BL.readFile templatePath
  let baseLocation = T.pack templatePath
  case parseYaml content baseLocation of
    Left (ParseError _pos msg) -> do
      TIO.hPutStrLn stderr $ "Parse error: " <> msg
      exitFailure
    Right ast -> do
      result <- preprocessYaml loadFileImport ast baseLocation
      case result of
        Left err -> do
          TIO.hPutStrLn stderr $ "Preprocess error: " <> showPreprocessError err
          exitFailure
        Right (PreprocessResult val _manifest) ->
          TIO.putStrLn (emitYaml val)

showPreprocessError :: PreprocessError -> T.Text
showPreprocessError = \case
  PeResolveError re -> "Resolve error: " <> T.pack (show re)
  PeImportError ie -> "Import error: " <> T.pack (show ie)
  PeHandlebarsError he -> "Handlebars error: " <> T.pack (show he)
  PeCycleError msg -> "Import cycle: " <> msg
