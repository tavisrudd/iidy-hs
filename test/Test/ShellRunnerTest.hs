-- | The shared bash runner ("Iidy.ShellRunner").
module Test.ShellRunnerTest (shellRunnerTests) where

import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.ShellRunner (bashProcess, exitDescription, runToExit)

-- | The shared runner reports exit codes and signals.
shellRunnerTests :: [TestTree]
shellRunnerTests =
    [ testCase "an exit code comes back" $ do
        code <- runToExit (bashProcess "exit 3" "." [])
        code @?= ExitFailure 3
        exitDescription code @?= "exit code 3"
    , testCase "a killed command reports its signal" $ do
        code <- runToExit (bashProcess "kill -9 $$" "." [])
        code @?= ExitFailure (-9)
        exitDescription code @?= "killed by signal 9"
    , testCase "the command runs in the directory with only the given environment" $
        withSystemTempDirectory "iidy-shell-runner" $ \dir -> do
            code <- runToExit (bashProcess "printf '%s' \"$PWD:$ONLY:${HOME:-unset}\" > out" dir [("ONLY", "yes")])
            code @?= ExitSuccess
            out <- readFile (dir </> "out")
            out @?= dir <> ":yes:unset"
    ]
