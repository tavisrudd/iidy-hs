{- | Tests for the demo command: script parsing, file unpacking, account
number masking, iidy command substitution, and end-to-end runs of generated
scripts. Only @bash -c@ one-liners that touch a test temp directory are run.
-}
module Test.DemoTest (demoTests) where

import Control.Exception (IOException, try)
import Data.Aeson (Value, eitherDecodeStrict, object, toJSON, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Error (ioeGetErrorString)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (DependencyType (..), TestTree, dependentTestGroup, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Iidy.Demo (
    DemoCommand (..),
    maskAwsAccountNumbers,
    parseDemoScript,
    runDemo,
    sleepMicros,
    substituteIidyCommand,
    typingDelayMicros,
    unpackFiles,
 )
import Iidy.Yaml.Imports.Types (RemoteImports (..), importPolicy)
import Test.ImportFixtures (flagPolicy)

demoTests :: [TestTree]
demoTests =
    [ testGroup "parseDemoScript" parseTests
    , testGroup "unpackFiles" unpackTests
    , testGroup "maskAwsAccountNumbers" maskTests
    , testGroup "delay rounding" delayTests
    , testGroup "substituteIidyCommand" substituteTests
    , -- runDemo uses the fixed directory <tmpdir>/iidy-demo and deletes it on
      -- exit (card C21 fixes that), so these must not overlap each other.
      dependentTestGroup "runDemo" AllFinish runTests
    ]

------------------------------------------------------------------------
-- parseDemoScript
------------------------------------------------------------------------

parseTests :: [TestTree]
parseTests =
    [ testCase "files and every command kind" $
        parseDemoScript
            ( object
                [ "files" .= object ["a.txt" .= ("hello" :: Text)]
                , "demo"
                    .= [ toJSON ("echo hi" :: Text)
                       , object ["silent" .= ("true" :: Text)]
                       , object ["sleep" .= (2 :: Int)]
                       , object ["banner" .= ("Title" :: Text)]
                       , object ["setenv" .= object ["K" .= ("v" :: Text)]]
                       ]
                ]
            )
            @?= Right
                ( Map.fromList [("a.txt", "hello")]
                ,
                    [ DemoShell "echo hi"
                    , DemoSilent "true"
                    , DemoSleep 2
                    , DemoBanner "Title"
                    , DemoSetEnv (Map.fromList [("K", "v")])
                    ]
                )
    , testCase "a fractional sleep value is kept (iidy-js demo.ts:123)" $
        fmap snd (parseDemoScript (object ["demo" .= [object ["sleep" .= (0.5 :: Double)]]]))
            @?= Right [DemoSleep 0.5]
    , testCase "a negative sleep value is rejected" $
        parseDemoScript (object ["demo" .= [object ["sleep" .= (-1 :: Int)]]])
            @?= Left "demo sleep must not be negative"
    , testCase "sleep values above a day are rejected (1e13, 1e300, 1e400, 1e1000000000)" $
        mapM_
            ( \lit -> do
                v <- either assertFailure pure (eitherDecodeStrict (TE.encodeUtf8 ("{\"demo\":[{\"sleep\":" <> lit <> "}]}")))
                parseDemoScript v @?= Left "demo sleep must not exceed 86400 seconds"
            )
            ["1e13", "1e300", "1e400", "1e1000000000"]
    , testCase "a sleep of exactly one day is accepted" $
        fmap snd (parseDemoScript (object ["demo" .= [object ["sleep" .= (86400 :: Int)]]]))
            @?= Right [DemoSleep 86400]
    , testCase "files are optional" $
        parseDemoScript (object ["demo" .= ([] :: [Value])]) @?= Right (Map.empty, [])
    , testCase "not a mapping" $
        parseDemoScript (toJSON ("x" :: Text)) @?= Left "demo script must be a mapping"
    , testCase "missing demo key" $
        parseDemoScript (object ["files" .= object []])
            @?= Left "demo script must have a 'demo' key with a sequence value"
    , testCase "unknown command" $
        parseDemoScript (object ["demo" .= [object ["frobnicate" .= ("x" :: Text)]]])
            @?= Left "unknown demo command format"
    , testCase "command neither string nor mapping" $
        parseDemoScript (object ["demo" .= [toJSON (5 :: Int)]])
            @?= Left "demo command must be a string or mapping"
    ]

------------------------------------------------------------------------
-- unpackFiles
------------------------------------------------------------------------

-- | The message of the IO error 'unpackFiles' raises for these files.
unpackError :: [(Text, Text)] -> IO String
unpackError files = withSystemTempDirectory "iidy-demo-test" $ \dir -> do
    r <- try (unpackFiles (Map.fromList files) dir)
    case r of
        Left (e :: IOException) -> pure (ioeGetErrorString e)
        Right () -> assertFailure "expected unpackFiles to fail"

unpackTests :: [TestTree]
unpackTests =
    [ testCase "writes relative files, creating subdirectories" $
        withSystemTempDirectory "iidy-demo-test" $ \dir -> do
            unpackFiles (Map.fromList [("sub/dir/f.txt", "body")]) dir
            TIO.readFile (dir </> "sub/dir/f.txt") >>= (@?= "body")
    , testCase "rejects an absolute path" $
        unpackError [("/etc/passwd", "x")]
            >>= (@?= "Illegal path /etc/passwd. Must be relative.")
    , testCase "rejects a parent directory reference" $
        unpackError [("../escape.txt", "x")]
            >>= (@?= "Illegal path ../escape.txt. Cannot contain parent directory references.")
    ]

------------------------------------------------------------------------
-- maskAwsAccountNumbers
------------------------------------------------------------------------

maskTests :: [TestTree]
maskTests =
    [ testCase "a 12-digit run is masked" $
        maskAwsAccountNumbers "acct 123456789012 ok" @?= "acct ************ ok"
    , testCase "every 12-digit run in the text is masked" $
        maskAwsAccountNumbers "111111111111,222222222222" @?= "************,************"
    , testCase "an 11-digit run is left alone" $
        maskAwsAccountNumbers "12345678901" @?= "12345678901"
    , testCase "a 13-digit run is left alone" $
        maskAwsAccountNumbers "1234567890123" @?= "1234567890123"
    , testCase "standalone number with surrounding spaces (demo.rs:490-510)" $
        maskAwsAccountNumbers "  account = 123456789012  " @?= "  account = ************  "
    , testCase "IAM role ARN (demo.rs:512-516)" $
        maskAwsAccountNumbers "arn:aws:iam::123456789012:role/MyRole"
            @?= "arn:aws:iam::************:role/MyRole"
    , testCase "STS assumed-role ARN (demo.rs:518-522)" $
        maskAwsAccountNumbers "arn:aws:sts::999888777666:assumed-role/Foo"
            @?= "arn:aws:sts::************:assumed-role/Foo"
    , testCase "IAM user ARN (demo.rs:524-528)" $
        maskAwsAccountNumbers "arn:aws:iam::111222333444:user/admin"
            @?= "arn:aws:iam::************:user/admin"
    , testCase "digits inside a longer word are left alone" $
        maskAwsAccountNumbers "abc123456789012 123456789012xyz"
            @?= "abc123456789012 123456789012xyz"
    ]

------------------------------------------------------------------------
-- sleepMicros / typingDelayMicros
------------------------------------------------------------------------

{- | iidy-hs rounds the scaled delay to the nearest microsecond. Rust truncates
whole seconds / milliseconds (demo.rs:134-136, 363-366); see DIVERGENCES.md.
-}
delayTests :: [TestTree]
delayTests =
    [ testCase "sleep 1 at timescaling 0.5 is 0.5s (Rust: 0s)" $
        sleepMicros 1 0.5 @?= 500000
    , testCase "sleep 1 at timescaling 1.5 is 1.5s (Rust: 1s)" $
        sleepMicros 1 1.5 @?= 1500000
    , testCase "sleep 0.5 at timescaling 1 is 0.5s" $
        sleepMicros 0.5 1 @?= 500000
    , testCase "sleep 0 is 0" $
        sleepMicros 0 1.5 @?= 0
    , testCase "sleep rounds to the nearest microsecond, not down" $
        sleepMicros 1.0000007 1 @?= 1000001
    , testCase "typing delay at timescaling 0.5 is 25ms (Rust: 25ms)" $
        typingDelayMicros 0.5 @?= 25000
    , testCase "typing delay at timescaling 1.5 is 75ms (Rust: 75ms)" $
        typingDelayMicros 1.5 @?= 75000
    , testCase "typing delay rounds to the nearest microsecond, not down" $
        typingDelayMicros 0.0000347 @?= 2
    ]

------------------------------------------------------------------------
-- substituteIidyCommand
------------------------------------------------------------------------

subst :: Text -> Text
subst cmd = substituteIidyCommand cmd (Just "/x/iidy") (importPolicy AllowRemoteImports)

substituteTests :: [TestTree]
substituteTests =
    [ testCase "command position" $ subst "iidy render a.yaml" @?= "/x/iidy render a.yaml"
    , testCase "after a pipe" $ subst "echo a | iidy render" @?= "echo a | /x/iidy render"
    , testCase "after a semicolon" $ subst "echo a; iidy render" @?= "echo a; /x/iidy render"
    , testCase "after &&" $ subst "true && iidy render" @?= "true && /x/iidy render"
    , testCase "inside parentheses" $ subst "(iidy render)" @?= "(/x/iidy render)"
    , testCase "an argument is left alone" $ subst "echo iidy" @?= "echo iidy"
    , testCase "blocked remote imports add --no-remote-imports" $
        substituteIidyCommand "iidy render" (Just "/x/iidy") (importPolicy BlockRemoteImports)
            @?= "/x/iidy --no-remote-imports render"
    , testCase "trusted import sources are passed through, quoted" $ do
        policy <- flagPolicy ["s3://b/", "https://t.example.com/it's/"]
        substituteIidyCommand "iidy render" (Just "/x/iidy") policy
            @?= "/x/iidy --trust-import-source 's3://b/' --trust-import-source 'https://t.example.com/it'\\''s/' render"
    , testCase "no executable and no flags leaves the command alone" $
        substituteIidyCommand "iidy render" Nothing (importPolicy AllowRemoteImports) @?= "iidy render"
    , testCase "iidy on PATH still receives --no-remote-imports" $
        substituteIidyCommand "iidy render | iidy lint" Nothing (importPolicy BlockRemoteImports)
            @?= "iidy --no-remote-imports render | iidy --no-remote-imports lint"
    , testCase "iidy on PATH still receives trusted import sources" $ do
        policy <- flagPolicy ["s3://b/"]
        substituteIidyCommand "iidy render" Nothing policy
            @?= "iidy --trust-import-source 's3://b/' render"
    ]

------------------------------------------------------------------------
-- runDemo end to end
------------------------------------------------------------------------

-- | Write @script@ into a fresh temp dir and run it with no sleeping or masking.
runScript :: Bool -> (FilePath -> Text) -> (FilePath -> Int -> IO a) -> IO a
runScript mask mkScript check = withSystemTempDirectory "iidy-demo-run" $ \dir -> do
    let path = dir </> "script.yaml"
    TIO.writeFile path (mkScript dir)
    rc <- runDemo (T.pack path) 0 mask (importPolicy BlockRemoteImports)
    check dir rc

markerExists :: FilePath -> IO Bool
markerExists dir = doesFileExist (dir </> "marker")

-- | A script whose single step writes @text@ to @<dir>/marker@.
writeMarker :: Text -> FilePath -> Text
writeMarker text dir =
    T.unlines ["demo:", "  - \"echo " <> text <> " > " <> T.pack dir <> "/marker\""]

runTests :: [TestTree]
runTests =
    [ testCase "a bash step runs: exit 0 and the marker file exists" $
        runScript False (writeMarker "ran") $ \dir rc -> do
            rc @?= 0
            TIO.readFile (dir </> "marker") >>= (@?= "ran\n")
    , testCase "masking mode runs the step too" $
        runScript True (writeMarker "masked") $ \dir rc -> do
            rc @?= 0
            TIO.readFile (dir </> "marker") >>= (@?= "masked\n")
    , testCase "silent, sleep and banner steps are accepted"
        $ runScript
            False
            ( \dir ->
                T.unlines
                    [ "demo:"
                    , "  - banner: Hello"
                    , "  - sleep: 3"
                    , "  - sleep: 0.5"
                    , "  - silent: \"echo quiet > " <> T.pack dir <> "/marker\""
                    ]
            )
        $ \dir rc -> do
            rc @?= 0
            TIO.readFile (dir </> "marker") >>= (@?= "quiet\n")
    , testCase "setenv reaches later steps and files are unpacked into the cwd"
        $ runScript
            False
            ( \dir ->
                T.unlines
                    [ "files:"
                    , "  greeting.txt: from-file"
                    , "demo:"
                    , "  - setenv: {DEMO_VAR: from-env}"
                    , "  - \"echo $DEMO_VAR $(cat greeting.txt) > " <> T.pack dir <> "/marker\""
                    ]
            )
        $ \dir rc -> do
            rc @?= 0
            TIO.readFile (dir </> "marker") >>= (@?= "from-env from-file\n")
    , testCase "a YAML parse error exits 1 and runs nothing" $
        runScript False (const "demo: [unclosed\n") $ \dir rc -> do
            rc @?= 1
            markerExists dir >>= assertBool "no step should run" . not
    , testCase "a repeated key exits 1 and runs nothing" $
        runScript False (\dir -> writeMarker "ran" dir <> "demo: []\n") $ \dir rc -> do
            rc @?= 1
            markerExists dir >>= assertBool "no step should run" . not
    , testCase "a preprocessing error exits 1 and runs nothing" $
        runScript False (const "demo: !$ no_such_variable\n") $ \dir rc -> do
            rc @?= 1
            markerExists dir >>= assertBool "no step should run" . not
    , testCase "a script that fails to parse exits 1" $
        runScript False (const "files: {}\n") $
            \_dir rc -> rc @?= 1
    , testCase "a failing step raises 'command failed'" $
        withSystemTempDirectory "iidy-demo-run" $ \dir -> do
            let path = dir </> "script.yaml"
            TIO.writeFile path "demo:\n  - \"exit 3\"\n"
            r <- try (runDemo (T.pack path) 0 False (importPolicy BlockRemoteImports))
            case r of
                Left (e :: IOException) -> ioeGetErrorString e @?= "command failed: exit 3"
                Right rc -> assertFailure ("expected an exception, got exit " <> show rc)
    ]
