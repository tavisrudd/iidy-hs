{- | Tests for the render command's output bytes, pinned to the Rust
original: JSON is @serde_json::to_string_pretty@ plus @println!@
(@render.rs:44@), YAML is @serialize_yaml_iidy_js_compatible@ (@render.rs:45@,
sequences indented under their key, unlike @serde_yaml@).
-}
module Test.RenderTest (renderTests) where

import Data.IORef (newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Amazonka qualified

import Iidy.Cli (RenderArgs (..), RenderFormat (..))
import Iidy.Render (runRenderWith)
import Iidy.Types (YamlSpec (..))
import Test.MockAws (MockAws (..), countingEnv, newMockAws, noCredentials)
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

renderFixture :: Text -> Text
renderFixture name = "test-fixtures/render/" <> name

renderTests :: [TestTree]
renderTests =
    [ testGroup "AWS environment" awsEnvTests
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
