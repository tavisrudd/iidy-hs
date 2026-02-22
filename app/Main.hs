module Main (main) where

import System.Exit (exitWith, ExitCode(..))
import System.IO (hPutStrLn, stderr)

import Iidy.Cli
import Iidy.Cli.Parser (parseCliOpts)
import Iidy.Explain (explainErrors)
import Iidy.Render (runRender)

main :: IO ()
main = do
  cli <- parseCliOpts
  runCommand cli

runCommand :: Cli -> IO ()
runCommand cli = case cliCommand cli of
  CmdRender args        -> runRender args (cliGlobalOpts cli) >>= \rc ->
                             exitWith (if rc == 0 then ExitSuccess else ExitFailure rc)
  CmdExplain codes      -> explainErrors codes
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
