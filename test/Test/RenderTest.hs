{- | Tests for the render command's output bytes, pinned to the Rust
original: JSON is @serde_json::to_string_pretty@ plus @println!@
(@render.rs:44@), YAML is @serialize_yaml_iidy_js_compatible@ (@render.rs:45@,
sequences indented under their key, unlike @serde_yaml@).
-}
module Test.RenderTest (renderTests) where

import Control.Exception (finally)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO (IOMode (..), hClose, hFlush, openFile, stderr)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (DependencyType (..), TestTree, dependentTestGroup, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Amazonka qualified

import Iidy.Cli (RenderArgs (..), RenderFormat (..))
import Iidy.Render (runRenderWith)
import Iidy.Types (YamlSpec (..))
import Iidy.Yaml.Imports.Loaders.LazyEnv (lazyAwsDispatcher)
import Iidy.Yaml.Imports.Types (ImportError (..), RemoteImports (..), importPolicy, rootBase)
import Test.MockAws (MockAws (..), MockMatch (..), MockResponse (..), countingEnv, mockRespond, newMockAws, noCredentials)
import Test.Shared (collectRawOutput, docFixture, listFixture, nestedSeqFixture, preprocTagsImporterFixture, testGlobalOpts)

-- | Render a fixture to stdout as JSON, returning exit code and raw output.
renderJson :: Text -> IO (Int, [Text])
renderJson = renderAs RenderJson

-- | Render a fixture to stdout in the given format, returning exit code and raw output.
renderAs :: RenderFormat -> Text -> IO (Int, [Text])
renderAs fmt path = do
    (emit, readOut) <- collectRawOutput
    rc <- runRenderWith noCredentials emit (renderArgs fmt path) (testGlobalOpts False)
    (,) rc <$> readOut

renderArgs :: RenderFormat -> Text -> RenderArgs
renderArgs fmt path =
    RenderArgs
        { raTemplate = path
        , raOutfile = "-"
        , raFormat = fmt
        , raQuery = Nothing
        , raOverwrite = False
        , raYamlSpec = YamlAuto
        }

-- | Outcome of one render run: exit code, raw output and env builds.
data RunResult = RunResult
    { rrExitCode :: !Int
    , rrOutput :: ![Text]
    , rrEnvBuilds :: !Int
    }
    deriving (Show, Eq)

-- | Render a fixture as JSON with an env provider, counting builds.
renderWithEnv :: Bool -> IO Amazonka.Env -> Text -> IO RunResult
renderWithEnv remote mkEnv path = do
    builds <- newIORef (0 :: Int)
    (emit, readOut) <- collectRawOutput
    rc <- runRenderWith (countingEnv builds mkEnv) emit (renderArgs RenderJson path) (testGlobalOpts remote)
    RunResult rc <$> readOut <*> readIORef builds

-- | Run an action with stderr redirected to a file, returning what it wrote.
captureStderr :: IO a -> IO (a, Text)
captureStderr act = withSystemTempDirectory "iidy-render-stderr" $ \dir -> do
    let path = dir <> "/stderr.txt"
    saved <- hDuplicate stderr
    h <- openFile path WriteMode
    hDuplicateTo h stderr
    r <- act `finally` (hFlush stderr >> hDuplicateTo saved stderr >> hClose h >> hClose saved)
    out <- TE.decodeUtf8 <$> BS.readFile path
    pure (r, out)

renderFixture :: Text -> Text
renderFixture name = "test-fixtures/render/" <> name

renderTests :: [TestTree]
renderTests =
    [ testGroup "AWS environment" awsEnvTests
    , -- stderr is process-wide: its captures must not overlap
      dependentTestGroup "AWS environment, stderr" AllFinish stderrTests
    , testGroup "output bytes" outputTests
    ]

awsEnvTests :: [TestTree]
awsEnvTests =
    [ testCase "ssm: import resolves through the mock env and the request is served" $ do
        mock <- newMockAws
        r <- renderWithEnv True (pure (mockEnv mock)) (renderFixture "ssm.yaml")
        r @?= RunResult 0 ["{\n  \"host\": \"db.internal.example\"\n}\n"] 1
        readIORef (mockRequests mock) >>= (@?= ["ssm.GetParameter.json"])
    , testCase "cfn:output import resolves through the mock env" $ do
        mock <- newMockAws
        r <- renderWithEnv True (pure (mockEnv mock)) (renderFixture "cfn.yaml")
        r @?= RunResult 0 ["{\n  \"vpc\": \"vpc-0abc123\"\n}\n"] 1
        readIORef (mockRequests mock) >>= (@?= ["cloudformation.DescribeStacks.xml"])
    , testCase "several AWS imports build the env exactly once" $ do
        mock <- newMockAws
        r <- renderWithEnv True (pure (mockEnv mock)) (renderFixture "twice.yaml")
        rrExitCode r @?= 0
        rrEnvBuilds r @?= 1
    , testCase "a file: import never builds the env" $
        renderWithEnv True noCredentials (renderFixture "file-import.yaml") >>= localOnly
    , testCase "an env: import never builds the env" $
        renderWithEnv True noCredentials (renderFixture "env-import.yaml") >>= localOnly
    , testCase "a template with no imports never builds the env" $
        renderWithEnv True noCredentials (renderFixture "no-imports.yaml") >>= localOnly
    , testCase "ssm: import without credentials exits 1 with no stdout" $ do
        r <- renderWithEnv True noCredentials (renderFixture "ssm.yaml")
        r @?= RunResult 1 [] 1
    , testCase "a failed env build is remembered: a second AWS import does not rerun the provider" $ do
        builds <- newIORef (0 :: Int)
        loader <- lazyAwsDispatcher (countingEnv builds noCredentials) (importPolicy AllowRemoteImports)
        r1 <- loader "ssm:/app/one" (rootBase ".")
        r2 <- loader "ssm:/app/two" (rootBase ".")
        let failed = either (\(ImportError e) -> "AWS credentials not available" `T.isInfixOf` e) (const False)
        (failed r1, failed r2) @?= (True, True)
        readIORef builds >>= (@?= 1)
    , testCase "s3: import with remote imports blocked never builds the env" $ do
        r <- renderWithEnv False noCredentials (renderFixture "s3.yaml")
        rrExitCode r @?= 1
        rrOutput r @?= []
        rrEnvBuilds r @?= 0
    ]
  where
    localOnly r = do
        rrExitCode r @?= 0
        rrEnvBuilds r @?= 0

stderrTests :: [TestTree]
stderrTests =
    duplicateKeyTests
        ++ [ testCase "ssm: import without credentials names the missing credentials on stderr" $ do
                (r, err) <- captureStderr (renderWithEnv True noCredentials (renderFixture "ssm.yaml"))
                rrExitCode r @?= 1
                assertBool ("stderr: " <> T.unpack err) ("AWS credentials not available" `T.isInfixOf` err)
           , testCase "an AWS import from an untrusted requester chain is refused without a build" $ do
                -- The local template may read s3: (one build); the s3 document is not
                -- a trusted source, so its own ssm: import is refused by the gate.
                mock <- newMockAws
                mockRespond mock (OnObject "GetObject" "tmpl" "doc.yaml") (MockResponse 200 (BC.pack "$imports:\n  p: ssm:/app/db-host\nv: !$ p\n"))
                (r, err) <- captureStderr (renderWithEnv True (pure (mockEnv mock)) (renderFixture "s3-chain.yaml"))
                rrExitCode r @?= 1
                rrOutput r @?= []
                assertBool ("stderr: " <> T.unpack err) ("not a trusted source" `T.isInfixOf` err)
                rrEnvBuilds r @?= 1
                served <- readIORef (mockRequests mock)
                filter ((== "ssm") . takeWhile (/= '.')) served @?= []
           ]

-- | Render @text@ written to a temp file as JSON, capturing stderr.
renderText :: BS.ByteString -> IO (RunResult, Text)
renderText text = withSystemTempDirectory "iidy-render-dup" $ \dir -> do
    let path = dir <> "/t.yaml"
    BS.writeFile path text
    captureStderr (renderWithEnv False noCredentials (T.pack path))

-- | A repeated mapping key is a parse error: exit 1, no output, and stderr names the key and its line.
rejectsRepeat :: Text -> Text -> Int -> BS.ByteString -> TestTree
rejectsRepeat name key line text = testCase ("repeated key rejected: " <> T.unpack name) $ do
    (r, err) <- renderText text
    rrExitCode r @?= 1
    rrOutput r @?= []
    let fragments = ["duplicate entry with key \"" <> key <> "\"", "t.yaml:" <> T.pack (show line) <> ":"]
    assertBool ("stderr: " <> T.unpack err) (all (`T.isInfixOf` err) fragments)

duplicateKeyTests :: [TestTree]
duplicateKeyTests =
    [ rejectsRepeat "top level" "a" 3 "a: 1\nb: 2\na: 3\n"
    , rejectsRepeat "nested" "Type" 4 "Resources:\n  R:\n    Type: X\n    Type: Y\n"
    , rejectsRepeat "a and \"a\"" "a" 2 "a: 1\n\"a\": 2\n"
    , testCase "1 and \"1\" are different keys and render" $ do
        (r, _) <- renderText "1: x\n\"1\": y\n"
        rrExitCode r @?= 0
    ]

outputTests :: [TestTree]
outputTests =
    [ testCase "render --format json: nested mapping is two-space with trailing newline" $
        renderJson docFixture
            >>= ( @?=
                    ( 0
                    , ["{\n  \"a\": 1,\n  \"b\": {\n    \"c\": \"x\",\n    \"d\": {}\n  }\n}\n"]
                    )
                )
    , testCase "render --format json: list is two-space, one element per line" $
        renderJson listFixture
            >>= (@?= (0, ["{\n  \"l\": [\n    \"x\",\n    \"y\"\n  ]\n}\n"]))
    , testCase "render --format yaml: sequences stay indented under their key" $
        renderAs RenderYaml nestedSeqFixture >>= (@?= (0, [nestedSeqRenderYaml]))
    , testCase "render --format yaml: an imported plain document keeps its !$ tags" $
        renderAs RenderYaml preprocTagsImporterFixture >>= (@?= (0, [preprocTagsRenderYaml]))
    ]

-- | Bytes printed by the Rust binary's @render@ for 'nestedSeqFixture' (C25).
nestedSeqRenderYaml :: Text
nestedSeqRenderYaml =
    T.unlines
        [ "a:"
        , "  c:"
        , "    - x"
        , "    - y"
        , "  grid:"
        , "    - - 1"
        , "      - 2"
        , "    - - 3"
        , "      - - 4"
        , "        - 5"
        , "  items:"
        , "    - deep:"
        , "        k:"
        , "          - p"
        , "          - q"
        , "      name: n1"
        , "      tags:"
        , "        - t1"
        , "        - t2"
        , "    - empty: []"
        , "      name: n2"
        , "top:"
        , "  - u"
        , "  - v"
        ]

-- | Bytes printed by the Rust binary's @render@ for 'preprocTagsImporterFixture' (C26).
preprocTagsRenderYaml :: Text
preprocTagsRenderYaml =
    T.unlines
        [ "out:"
        , "  a: !$ secret"
        , "  b: !$map"
        , "    items:"
        , "      - 1"
        , "      - 2"
        , "    template: '{{item}}'"
        , "seq:"
        , "  c: !$join"
        , "    - ','"
        , "    - - a"
        , "      - b"
        ]
