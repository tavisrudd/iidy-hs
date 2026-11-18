{- | CommandsBefore through the stack-args loader: classified, dry-run,
run, then the imports resolved again (card C40). Every command is a
harmless local one writing marker files under a temporary directory, with
stdin from @/dev/null@; no network, no AWS.
-}
module Test.CommandsBeforeLoadTest (commandsBeforeLoadTests) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO (IOMode (..), hClose, openFile)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Cfn.CommandsBefore (
    CommandsBeforeSettings (..),
    commandOutputOn,
    defaultCommandsBeforeSettings,
 )
import Iidy.Cfn.StackArgsLoader (LoadedStackArgs (..), loadStackArgsWithSettings)
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..))
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher, mkImportConfig)
import Iidy.Yaml.Imports.Types (RemoteImports (..), importPolicy)
import Test.Shared (noAwsSettings)

commandsBeforeLoadTests :: [TestTree]
commandsBeforeLoadTests =
    [ testGroup "runs" runTests
    , testGroup "refused before anything runs" refusalTests
    , testGroup "failures" failureTests
    , testGroup "output and stdin" ioTests
    ]

-- | What a load did: its result and what it wrote to stdout and stderr.
data Outcome = Outcome
    { oResult :: Either Text LoadedStackArgs
    , oStdout :: Text
    , oStderr :: Text
    }

-- | Load @stack-args.yaml@ (written from the text) in a fresh directory.
loadIn :: FilePath -> CommandsBeforeSettings -> Bool -> CfnOperation -> Text -> IO Outcome
loadIn dir settings json op yaml = do
    let argsfile = dir </> "stack-args.yaml"
        logs = dir </> "logs"
        policy = importPolicy AllowRemoteImports
    createDirectoryIfMissing True logs
    TIO.writeFile argsfile yaml
    out <- openFile (logs </> "stdout") WriteMode
    err <- openFile (logs </> "stderr") WriteMode
    result <-
        loadStackArgsWithSettings
            settings{cbsOutput = commandOutputOn out err json}
            policy
            (\_ast -> pure (mkFullDispatcher (mkImportConfig Nothing policy)))
            argsfile
            "dev"
            op
            noAwsSettings
    hClose out
    hClose err
    Outcome result <$> TIO.readFile (logs </> "stdout") <*> TIO.readFile (logs </> "stderr")

-- | 'loadIn' with the default settings, plain output, for create-stack.
load :: FilePath -> Text -> IO Outcome
load dir = loadIn dir defaultCommandsBeforeSettings False OpCreateStack

-- | Stack-args lines every test file starts with.
header :: [Text]
header = ["StackName: test-stack", "Template: template.yaml"]

builtHash, oldHash :: Text
builtHash = "586a866f990ab55e36decfffc2011f172e4452d5141c939a5436baffba11111d"
oldHash = "cba06b5736faf67e54b07b561eae94395e774c517a7d910a54369e1263ccfbd4"

loaded :: Outcome -> IO StackArgs
loaded o = case oResult o of
    Left err -> assertFailure ("load failed: " <> T.unpack err <> "\nstderr: " <> T.unpack (oStderr o))
    Right r -> pure (lsaStackArgs r)

refused :: [Text] -> Outcome -> Assertion
refused needles o = case oResult o of
    Right _ -> assertFailure "expected the load to be refused"
    Left err -> mapM_ (\t -> assertBool ("error mentions " <> T.unpack t <> ": " <> T.unpack err) (t `T.isInfixOf` err)) needles

hasFile :: FilePath -> FilePath -> IO Bool
hasFile dir name = doesFileExist (dir </> name)

assertNoMarker :: FilePath -> Assertion
assertNoMarker dir = hasFile dir "marker" >>= assertBool "a command ran" . not

runTests :: [TestTree]
runTests =
    [ testCase "a def, an import, iidy.region and filehash of a built file expand and run" $
        withSystemTempDirectory "iidy-cb" $ \dir -> do
            createDirectoryIfMissing True (dir </> "dist")
            TIO.writeFile (dir </> "dist" </> "app.zip") "old"
            TIO.writeFile (dir </> "params.yaml") "prefix: pre\n"
            o <-
                load dir . T.unlines $
                    header
                        <> [ "Region: us-west-2"
                           , "$defs:"
                           , "  bucket: my-bucket"
                           , "$imports:"
                           , "  params: params.yaml"
                           , "  appHash: filehash:dist/app.zip"
                           , "Parameters:"
                           , "  Hash: !$ appHash"
                           , "CommandsBefore:"
                           , "  - printf built > dist/app.zip"
                           , "  - printf '%s' \"{{ bucket }} {{params.prefix}} {{iidy.region}} {{filehash 'dist/app.zip'}} $iidy_region $iidy_environment\" > ran.txt"
                           ]
            sa <- loaded o
            ran <- TIO.readFile (dir </> "ran.txt")
            ran @?= "my-bucket pre us-west-2 " <> builtHash <> " us-west-2 dev"
            -- the expanded text is what the final document keeps
            saCommandsBefore sa
                @?= Just
                    [ "printf built > dist/app.zip"
                    , "printf '%s' \"my-bucket pre us-west-2 " <> builtHash <> " $iidy_region $iidy_environment\" > ran.txt"
                    ]
            -- the import is resolved again after the commands
            fmap (Map.lookup "Hash") (saParameters sa) @?= Just (Just builtHash)
            assertBool "the old hash is gone" (oldHash `notElem` maybe [] Map.elems (saParameters sa))
            assertBool ("banner on stdout: " <> T.unpack (oStdout o)) ("== Executing CommandsBefore" `T.isInfixOf` oStdout o)
            assertBool "raw and expanded text shown" ("# command after processing handlebars variables:" `T.isInfixOf` oStdout o)
    , testCase "the region the AWS environment is built with, and the CLI stack name" $
        withSystemTempDirectory "iidy-cb" $ \dir -> do
            let settings =
                    defaultCommandsBeforeSettings
                        { cbsResolveRegion = \_merged -> pure (Just "eu-central-1")
                        , cbsStackName = Just "cli-stack"
                        }
            o <- loadIn dir settings False OpCreateStack . T.unlines $ header <> ["CommandsBefore:", "  - printf '%s' {{iidy.region}}-{{region}}-{{iidy.stackName}}-$iidy_region > ran.txt"]
            _ <- loaded o
            TIO.readFile (dir </> "ran.txt") >>= (@?= "eu-central-1-eu-central-1-cli-stack-eu-central-1")
    , testCase "iidy.stackArgs is the document without CommandsBefore" $
        withSystemTempDirectory "iidy-cb" $ \dir -> do
            o <- load dir . T.unlines $ header <> ["Parameters:", "  Env: prod", "CommandsBefore:", "  - printf '%s' {{iidy.stackArgs.Parameters.Env}}-{{iidy.stackArgs.StackName}} > ran.txt"]
            _ <- loaded o
            TIO.readFile (dir </> "ran.txt") >>= (@?= "prod-test-stack")
    ]

refusalTests :: [TestTree]
refusalTests =
    [ testCase ("a value that " <> what <> " is refused") $
        withSystemTempDirectory "iidy-cb" $ \dir -> do
            o <- load dir . T.unlines $ header <> ["$defs:", "  bad: " <> yamlValue, "CommandsBefore:", "  - touch marker", "  - echo {{ bad }}"]
            refused ["CommandsBefore[1]", "{{bad}}", "the $defs name bad", problem] o
            assertNoMarker dir
    | (what, yamlValue, problem) <-
        [ ("has a space", "\"a b\"", "contains a space")
        , ("has a single quote", "\"a'b\"", "contains the character '\\''")
        , ("has a double quote", "'a\"b'", "contains the character '\"'")
        , ("has a dollar", "\"$HOME\"", "contains the character '$'")
        , ("has a backquote", "\"`id`\"", "contains the character '`'")
        , ("has a semicolon", "\"a;b\"", "contains the character ';'")
        , ("has a pipe", "\"a|b\"", "contains the character '|'")
        , ("has an ampersand", "\"a&b\"", "contains the character '&'")
        , ("has a less-than", "\"a<b\"", "contains the character '<'")
        , ("has a newline", "\"a\\nb\"", "contains a newline")
        , ("has a star", "\"a*\"", "contains the character '*'")
        , ("starts with -", "\"-rf\"", "starts with -")
        , ("is empty", "\"\"", "is empty")
        ]
    ]
        <> [ testCase "a tagged entry is refused" $
                withSystemTempDirectory "iidy-cb" $ \dir -> do
                    o <- load dir . T.unlines $ header <> ["$defs:", "  c: touch marker", "CommandsBefore:", "  - touch marker", "  - !$ c"]
                    refused ["CommandsBefore[1] is a preprocessing tag"] o
                    assertNoMarker dir
           , testCase "an imported list is refused" $
                withSystemTempDirectory "iidy-cb" $ \dir -> do
                    TIO.writeFile (dir </> "cmds.yaml") "- touch marker\n"
                    o <- load dir . T.unlines $ header <> ["$imports:", "  cmds: cmds.yaml", "CommandsBefore: !$ cmds"]
                    refused ["CommandsBefore is a preprocessing tag"] o
                    assertNoMarker dir
           , testCase "a CommandsBefore made by a computed key is refused" $
                withSystemTempDirectory "iidy-cb" $ \dir -> do
                    o <- load dir . T.unlines $ header <> ["$defs:", "  k: CommandsBefore", "\"{{k}}\":", "  - touch marker"]
                    refused ["CommandsBefore", "computed"] o
                    assertNoMarker dir
           , testCase "a computed key next to a written list is refused" $
                withSystemTempDirectory "iidy-cb" $ \dir -> do
                    o <- load dir . T.unlines $ header <> ["$defs:", "  k: CommandsBefore", "CommandsBefore:", "  - touch marker", "\"{{k}}\":", "  - touch marker"]
                    refused ["CommandsBefore", "computed"] o
                    assertNoMarker dir
           , testCase "filehash with a non-literal path is refused" $
                withSystemTempDirectory "iidy-cb" $ \dir -> do
                    o <- load dir . T.unlines $ header <> ["$defs:", "  f: app.zip", "CommandsBefore:", "  - touch marker", "  - echo {{filehash f}}"]
                    refused ["CommandsBefore[1]", "literal path"] o
                    assertNoMarker dir
           , testCase "a $defs or $imports name that clashes with a built-in name is refused" $
                mapM_
                    ( \name -> withSystemTempDirectory "iidy-cb" $ \dir -> do
                        o <- load dir . T.unlines $ header <> ["$defs:", "  " <> name <> ": x", "CommandsBefore:", "  - touch marker"]
                        refused [name, "built-in"] o
                        assertNoMarker dir
                    )
                    ["region", "environment", "iidy"]
           , testCase "an unresolved region is refused as empty" $
                withSystemTempDirectory "iidy-cb" $ \dir -> do
                    o <- load dir . T.unlines $ header <> ["CommandsBefore:", "  - touch marker", "  - echo {{iidy.region}}"]
                    refused ["{{iidy.region}}", "is empty"] o
                    assertNoMarker dir
           ]

failureTests :: [TestTree]
failureTests =
    [ testCase "a failing command stops the load with its exit code" $
        withSystemTempDirectory "iidy-cb" $ \dir -> do
            o <- load dir . T.unlines $ header <> ["CommandsBefore:", "  - exit 7", "  - touch marker"]
            refused ["Error running command (exit code 7):", "exit 7"] o
            assertNoMarker dir
    , testCase "a killed command fails the load" $
        withSystemTempDirectory "iidy-cb" $ \dir -> do
            o <- load dir . T.unlines $ header <> ["CommandsBefore:", "  - kill -9 $$", "  - touch marker"]
            refused ["killed by signal 9", "kill -9 $$"] o
            assertNoMarker dir
    ]

ioTests :: [TestTree]
ioTests =
    [ testCase "json output mode keeps stdout clear of banners and child output" $
        withSystemTempDirectory "iidy-cb" $ \dir -> do
            o <- loadIn dir defaultCommandsBeforeSettings True OpCreateStack . T.unlines $ header <> ["CommandsBefore:", "  - echo child-stdout; echo child-stderr >&2"]
            _ <- loaded o
            oStdout o @?= ""
            mapM_
                (\t -> assertBool ("stderr has " <> T.unpack t <> ": " <> T.unpack (oStderr o)) (t `T.isInfixOf` oStderr o))
                ["== Executing CommandsBefore", "child-stdout", "child-stderr"]
    , testCase "plain output mode sends child stdout to stdout" $
        withSystemTempDirectory "iidy-cb" $ \dir -> do
            o <- load dir . T.unlines $ header <> ["CommandsBefore:", "  - echo out-$((1+1)); echo err-$((2+1)) >&2"]
            _ <- loaded o
            assertBool "stdout has child output" ("out-2" `T.isInfixOf` oStdout o)
            assertBool "stderr has child stderr" ("err-3" `T.isInfixOf` oStderr o)
            assertBool "stdout lacks child stderr" (not ("err-3" `T.isInfixOf` oStdout o))
    , testCase "stdin is /dev/null when it is not a terminal" $
        withSystemTempDirectory "iidy-cb" $ \dir -> do
            o <- load dir . T.unlines $ header <> ["CommandsBefore:", "  - readlink /proc/$$/fd/0 > stdin.txt"]
            _ <- loaded o
            TIO.readFile (dir </> "stdin.txt") >>= (@?= "/dev/null\n")
    , testCase "the iidy_* variables and the bash helper functions are set" $
        withSystemTempDirectory "iidy-cb" $ \dir -> do
            o <- load dir . T.unlines $ header <> ["Region: us-east-2", "CommandsBefore:", "  - printf '%s %s' \"$iidy_region\" \"$(type -t iidy_filehash iidy_filehash_base64 iidy_s3_upload | tr '\\n' ,)\" > env.txt"]
            _ <- loaded o
            TIO.readFile (dir </> "env.txt") >>= (@?= "us-east-2 function,function,function,")
    ]
