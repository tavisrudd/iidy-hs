{- | Tests for the get-import command: AWS-backed imports resolve through a
mock AWS env, and the env is only built when the import type needs it.
-}
module Test.GetImportTest (getImportTests) where

import Control.Exception (throwIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Amazonka qualified
import Amazonka.Auth.Exception qualified as AuthEx

import Iidy.Cli (GetImportArgs (..), RenderFormat (..))
import Iidy.GetImport (needsAwsEnv, runGetImportWith)
import Iidy.Yaml.Imports.Types (ImportType (..), RemoteImports (..))
import Test.MockAws (MockAws (..), newMockAws)
import Test.Shared (collectRawOutput, docFixture, listFixture, nestedSeqFixture, orderedJsonFixture, orderedNestedFixture, orderedYamlFixture, preprocTagsFixture, surrogateJsonFixture, testGlobalOpts)

getImportTests :: [TestTree]
getImportTests =
    [ testGroup "AWS imports via mock env" mockAwsTests
    , testGroup "env built only when needed" lazinessTests
    , testGroup "env construction failures" failureTests
    , testGroup "query and output layout" outputTests
    , testGroup "serde_yaml sequence layout" sequenceLayoutTests
    , testGroup "unresolved tags in plain documents" preprocTagTests
    , testGroup "document key order" keyOrderTests
    , testCase "needsAwsEnv classifies every import type" needsAwsEnvTable
    ]

------------------------------------------------------------------------
-- Harness
------------------------------------------------------------------------

-- | Outcome of one get-import run.
data RunResult = RunResult
    { rrExitCode :: !Int
    , rrOutput :: ![Text]
    , rrEnvBuilds :: !Int
    }
    deriving (Show, Eq)

jsonArgs :: Text -> GetImportArgs
jsonArgs loc = GetImportArgs{giaImport = loc, giaFormat = RenderJson, giaQuery = Nothing}

-- | Run get-import with the given args, counting env builds and collecting raw output.
runArgs :: Bool -> IO Amazonka.Env -> GetImportArgs -> IO RunResult
runArgs remote mkEnv args = do
    builds <- newIORef (0 :: Int)
    (emit, readOut) <- collectRawOutput
    let countedEnv = bump builds >> mkEnv
    rc <- runGetImportWith countedEnv emit args (testGlobalOpts remote)
    RunResult rc <$> readOut <*> readIORef builds

-- | Run get-import as JSON, counting env builds and collecting raw output.
runWith :: Bool -> IO Amazonka.Env -> Text -> IO RunResult
runWith remote mkEnv loc = runArgs remote mkEnv (jsonArgs loc)

-- | Run get-import on a local file with an explicit format and query.
runFormat :: RenderFormat -> Maybe Text -> Text -> IO RunResult
runFormat fmt query loc =
    runArgs False noCredentials GetImportArgs{giaImport = loc, giaFormat = fmt, giaQuery = query}

bump :: IORef Int -> IO ()
bump ref = atomicModifyIORef' ref (\n -> (n + 1, ()))

-- | An env provider that fails like 'Amazonka.discover' without credentials.
noCredentials :: IO Amazonka.Env
noCredentials = throwIO AuthEx.CredentialChainExhausted

------------------------------------------------------------------------
-- Mock-backed AWS imports
------------------------------------------------------------------------

mockAwsTests :: [TestTree]
mockAwsTests =
    [ testCase "ssm: parameter resolves" $ do
        mock <- newMockAws
        r <- runWith True (pure (mockEnv mock)) "ssm:/app/db-host"
        r @?= RunResult 0 ["\"db.internal.example\"\n"] 1
        served <- readIORef (mockRequests mock)
        served @?= ["ssm.GetParameter.json"]
    , testCase "cfn:output stack/key resolves" $ do
        mock <- newMockAws
        r <- runWith True (pure (mockEnv mock)) "cfn:output:network-stack/VpcId"
        r @?= RunResult 0 ["\"vpc-0abc123\"\n"] 1
        served <- readIORef (mockRequests mock)
        served @?= ["cloudformation.DescribeStacks.xml"]
    , testCase "cfn:output stack resolves all outputs" $ do
        mock <- newMockAws
        r <- runWith True (pure (mockEnv mock)) "cfn:output:network-stack"
        rrExitCode r @?= 0
        rrOutput r @?= ["{\n  \"SubnetId\": \"subnet-0def456\",\n  \"VpcId\": \"vpc-0abc123\"\n}\n"]
    ]

------------------------------------------------------------------------
-- Laziness (Rust resolves credentials only on the first AWS call)
------------------------------------------------------------------------

lazinessTests :: [TestTree]
lazinessTests =
    [ testCase "file import never builds the env" $ do
        r <- runWith True noCredentials "test-fixtures/template-loader/simple.yaml"
        rrExitCode r @?= 0
        rrEnvBuilds r @?= 0
    , testCase "env: import never builds the env" $ do
        r <- runWith True noCredentials "env:IIDY_C7_UNSET_VAR:fallback"
        r @?= RunResult 0 ["\"fallback\"\n"] 0
    , testCase "s3 import with remote imports blocked never builds the env" $ do
        r <- runWith False noCredentials "s3://bucket/key.yaml"
        rrExitCode r @?= 1
        rrEnvBuilds r @?= 0
    ]

------------------------------------------------------------------------
-- Failures (Rust: one "Import error: ..." line on stderr, exit 1)
------------------------------------------------------------------------

failureTests :: [TestTree]
failureTests =
    [ testCase "ssm: without credentials exits 1 with no output" $ do
        r <- runWith True noCredentials "ssm:/app/db-host"
        r @?= RunResult 1 [] 1
    , testCase "cfn: without credentials exits 1 with no output" $ do
        r <- runWith True noCredentials "cfn:output:network-stack/VpcId"
        r @?= RunResult 1 [] 1
    , testCase "nonexistent local file exits 1 with no stdout" $
        runWith False noCredentials "test-fixtures/get-import/no-such-file.yaml"
            >>= (@?= RunResult 1 [] 0)
    , testCase "env: with no default and the variable unset exits 1 with no stdout" $
        runWith False noCredentials "env:IIDY_C11_UNSET_VAR"
            >>= (@?= RunResult 1 [] 0)
    , testCase "missing region exits 1 with no output" $ do
        r <- runWith True (throwIO (userError "No AWS region configured.")) "ssm-path:/app"
        r @?= RunResult 1 [] 1
    ]

------------------------------------------------------------------------
-- Classification
------------------------------------------------------------------------

needsAwsEnvTable :: IO ()
needsAwsEnvTable = do
    let allTypes =
            [ ImportFile
            , ImportEnv
            , ImportGit
            , ImportRandom
            , ImportFilehash
            , ImportFilehashBase64
            , ImportCfn
            , ImportSsm
            , ImportSsmPath
            , ImportS3
            , ImportHttp
            ]
    filter (needsAwsEnv AllowRemoteImports) allTypes @?= [ImportCfn, ImportSsm, ImportSsmPath, ImportS3]
    filter (needsAwsEnv BlockRemoteImports) allTypes @?= [ImportCfn, ImportSsm, ImportSsmPath]

------------------------------------------------------------------------
-- --query and exact output text (Rust get_import.rs:45-64)
------------------------------------------------------------------------

outputTests :: [TestTree]
outputTests =
    [ testCase "field query: a gives 1" $
        runFormat RenderYaml (Just "a") docFixture >>= (@?= RunResult 0 ["1\n"] 0)
    , testCase "nested query: b.c gives x" $
        runFormat RenderYaml (Just "b.c") docFixture >>= (@?= RunResult 0 ["x\n"] 0)
    , testCase "indexing query: l[1] gives y" $
        runFormat RenderYaml (Just "l[1]") listFixture >>= (@?= RunResult 0 ["y\n"] 0)
    , testCase "invalid query exits 1 with no stdout" $
        runFormat RenderYaml (Just "a[") docFixture >>= (@?= RunResult 1 [] 0)
    , testCase "yaml output ends with exactly one newline" $
        runFormat RenderYaml Nothing docFixture
            >>= (@?= RunResult 0 ["a: 1\nb:\n  c: x\n  d: {}\n"] 0)
    , testCase "json output is pretty-printed like serde_json" $
        runFormat RenderJson Nothing docFixture
            >>= ( @?=
                    RunResult
                        0
                        ["{\n  \"a\": 1,\n  \"b\": {\n    \"c\": \"x\",\n    \"d\": {}\n  }\n}\n"]
                        0
                )
    , testCase "json arrays are pretty-printed one element per line" $
        runFormat RenderJson Nothing listFixture
            >>= (@?= RunResult 0 ["{\n  \"l\": [\n    \"x\",\n    \"y\"\n  ]\n}\n"] 0)
    ]

------------------------------------------------------------------------
-- serde_yaml sequence layout (Rust get_import.rs:56 uses serde_yaml)
------------------------------------------------------------------------

-- | Bytes printed by the Rust binary for 'nestedSeqFixture' (recorded in C25).
nestedSeqRustYaml :: Text
nestedSeqRustYaml =
    T.unlines
        [ "a:"
        , "  c:"
        , "  - x"
        , "  - y"
        , "  grid:"
        , "  - - 1"
        , "    - 2"
        , "  - - 3"
        , "    - - 4"
        , "      - 5"
        , "  items:"
        , "  - deep:"
        , "      k:"
        , "      - p"
        , "      - q"
        , "    name: n1"
        , "    tags:"
        , "    - t1"
        , "    - t2"
        , "  - empty: []"
        , "    name: n2"
        , "top:"
        , "- u"
        , "- v"
        ]

sequenceLayoutTests :: [TestTree]
sequenceLayoutTests =
    [ testCase "yaml: dashes sit at the parent key's indent" $
        runFormat RenderYaml Nothing nestedSeqFixture
            >>= (@?= RunResult 0 [nestedSeqRustYaml] 0)
    ]

------------------------------------------------------------------------
-- Unresolved !$ tags in a plain imported document (Rust keeps them)
------------------------------------------------------------------------

-- | Bytes printed by the Rust binary for 'preprocTagsFixture' (C26).
preprocTagsRustYaml :: Text
preprocTagsRustYaml =
    T.unlines
        [ "a: !$ secret"
        , "b: !$map"
        , "  items:"
        , "  - 1"
        , "  - 2"
        , "  template: '{{item}}'"
        ]

preprocTagTests :: [TestTree]
preprocTagTests =
    [ testCase "yaml: scalar and mapping tag arguments are kept" $
        runFormat RenderYaml Nothing preprocTagsFixture
            >>= (@?= RunResult 0 [preprocTagsRustYaml] 0)
    ]

------------------------------------------------------------------------
-- Document key order (Rust keeps it for unqueried YAML output only)
------------------------------------------------------------------------

keyOrderTests :: [TestTree]
keyOrderTests =
    [ testCase "yaml: top-level keys keep document order" $
        yamlOf orderedYamlFixture ["z:", "- 1", "a: 2"]
    , testCase "yaml: nested keys keep document order" $
        yamlOf orderedNestedFixture ["k:", "  z: 1", "  a: 2", "m: x"]
    , testCase "yaml: a .json file keeps its key order" $
        yamlOf orderedJsonFixture ["z: 1", "a:", "  y: 1", "  b: 2"]
    , testCase "yaml: a .json surrogate-pair escape prints the character" $
        yamlOf surrogateJsonFixture ["e: \128512", "a: 1"]
    , testCase "json: output stays sorted" $
        runFormat RenderJson Nothing orderedYamlFixture
            >>= (@?= RunResult 0 ["{\n  \"a\": 2,\n  \"z\": [\n    1\n  ]\n}\n"] 0)
    , testCase "query: a result stays sorted" $
        runFormat RenderYaml (Just "@") orderedNestedFixture
            >>= (@?= RunResult 0 [T.unlines ["k:", "  a: 2", "  z: 1", "m: x"]] 0)
    , testCase "query: a sub-document stays sorted" $
        runFormat RenderYaml (Just "k") orderedNestedFixture
            >>= (@?= RunResult 0 [T.unlines ["a: 2", "z: 1"]] 0)
    , testCase "yaml: an env: scalar is unchanged" $
        runFormat RenderYaml Nothing "env:IIDY_C28_UNSET_VAR:fallback"
            >>= (@?= RunResult 0 ["fallback\n"] 0)
    ]
  where
    yamlOf loc ls = runFormat RenderYaml Nothing loc >>= (@?= RunResult 0 [T.unlines ls] 0)
