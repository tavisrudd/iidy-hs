module Main (main) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure, exitWith, ExitCode(..))
import System.IO (hPutStrLn, stderr)

import Iidy.Cli
import Iidy.Cli.Parser (parseCliOpts)
import Iidy.Yaml.Engine (preprocessYaml, PreprocessResult(..), PreprocessError(..))
import Iidy.Yaml.Emitter (emitYaml)
import Iidy.Yaml.Imports.Loaders.File (loadFileImport)
import Iidy.Yaml.Parser (parseYaml, ParseError(..))

main :: IO ()
main = do
  cli <- parseCliOpts
  runCommand cli

runCommand :: Cli -> IO ()
runCommand cli = case cliCommand cli of
  CmdRender args        -> renderCommand args
  CmdExplain codes      -> explainCommand codes
  CmdCreateStack _      -> notImplemented "create-stack"
  CmdUpdateStack _      -> notImplemented "update-stack"
  CmdCreateOrUpdate _   -> notImplemented "create-or-update"
  CmdEstimateCost _     -> notImplemented "estimate-cost"
  CmdCreateChangeset _  -> notImplemented "create-changeset"
  CmdExecChangeset _    -> notImplemented "exec-changeset"
  CmdDescribeStack _    -> notImplemented "describe-stack"
  CmdWatchStack _       -> notImplemented "watch-stack"
  CmdDescribeStackDrift _ -> notImplemented "describe-stack-drift"
  CmdDeleteStack _      -> notImplemented "delete-stack"
  CmdGetStackTemplate _ -> notImplemented "get-stack-template"
  CmdGetStackInstances _ -> notImplemented "get-stack-instances"
  CmdListStacks _       -> notImplemented "list-stacks"
  CmdParam _            -> notImplemented "param"
  CmdTemplateApproval _ -> notImplemented "template-approval"
  CmdGetImport _        -> notImplemented "get-import"
  CmdDemo _             -> notImplemented "demo"
  CmdLintTemplate _     -> notImplemented "lint-template"
  CmdConvertStackToIidy _ -> notImplemented "convert-stack-to-iidy"
  CmdInitStackArgs _    -> notImplemented "init-stack-args"
  CmdCompletion _       -> notImplemented "completion"

notImplemented :: String -> IO ()
notImplemented cmd = do
  hPutStrLn stderr $ "iidy-hs: command '" <> cmd <> "' not yet implemented"
  exitWith (ExitFailure 1)

------------------------------------------------------------------------
-- render command
------------------------------------------------------------------------

renderCommand :: RenderArgs -> IO ()
renderCommand args = do
  let templatePath = T.unpack (raTemplate args)
  content <- if templatePath == "-"
    then BL.getContents
    else BL.readFile templatePath
  let baseLocation = raTemplate args
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
        Right (PreprocessResult val _manifest) -> do
          let outPath = T.unpack (raOutfile args)
          let rendered = emitYaml val
          if outPath == "-"
            then TIO.putStrLn rendered
            else TIO.writeFile outPath rendered

showPreprocessError :: PreprocessError -> T.Text
showPreprocessError = \case
  PeResolveError re    -> "Resolve error: " <> T.pack (show re)
  PeImportError ie     -> "Import error: " <> T.pack (show ie)
  PeHandlebarsError he -> "Handlebars error: " <> T.pack (show he)
  PeCycleError msg     -> "Import cycle: " <> msg

------------------------------------------------------------------------
-- explain command
------------------------------------------------------------------------

explainCommand :: [T.Text] -> IO ()
explainCommand [] = do
  hPutStrLn stderr "Usage: iidy-hs explain <CODE>..."
  exitFailure
explainCommand codes = do
  mapM_ explainCode codes

explainCode :: T.Text -> IO ()
explainCode code =
  TIO.putStrLn $ "No explanation available for error code: " <> code
