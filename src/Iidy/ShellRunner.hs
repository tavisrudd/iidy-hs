{- | The one way iidy-hs runs operator shell text: @bash -c@ found on
@PATH@ (@/usr/bin/env bash@), in a given directory, with exactly the given
environment. Used by @demo@ ("Iidy.Demo") and by @CommandsBefore@
("Iidy.Cfn.CommandsBefore").
-}
module Iidy.ShellRunner (
    bashProcess,
    runToExit,
    exitDescription,
) where

import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (..), proc, waitForProcess, withCreateProcess)

{- | The process for @bash -c COMMAND@ in the directory, with the
environment as given (not merged with the parent's). Standard streams are
inherited unless the caller sets them.
-}
bashProcess :: Text -> FilePath -> [(String, String)] -> CreateProcess
bashProcess command workDir envList =
    (proc "/usr/bin/env" ["bash", "-c", T.unpack command])
        { cwd = Just workDir
        , env = Just envList
        }

{- | Run a process whose streams the caller does not read and wait for it.
A process killed by a signal gives @'ExitFailure' (-signal)@.
-}
runToExit :: CreateProcess -> IO ExitCode
runToExit p = withCreateProcess p (\_stdin _stdout _stderr ph -> waitForProcess ph)

-- | An exit status for messages: "exit code N" or "killed by signal N".
exitDescription :: ExitCode -> Text
exitDescription = \case
    ExitSuccess -> "exit code 0"
    ExitFailure n
        | n < 0 -> "killed by signal " <> T.pack (show (negate n))
        | otherwise -> "exit code " <> T.pack (show n)
