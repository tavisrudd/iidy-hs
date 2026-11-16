{- | Tests for the get-import command: AWS-backed imports resolve through a
mock AWS env, and the env is only built when the import type needs it.
-}
module Test.GetImportTest (getImportTests) where

import Control.Exception (throwIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Amazonka qualified
import Amazonka.Auth.Exception qualified as AuthEx

import Iidy.Cli (GetImportArgs (..), GlobalOpts (..), RenderFormat (..))
import Iidy.GetImport (needsAwsEnv, runGetImportWith)
import Iidy.Output.Types (OutputData (..))
import Iidy.Types (ColorChoice (..), Theme (..))
import Iidy.Yaml.Imports.Types (ImportType (..), RemoteImports (..))
import Test.MockAws (MockAws (..), newMockAws)

getImportTests :: [TestTree]
getImportTests =
    [ testGroup "AWS imports via mock env" mockAwsTests
    , testGroup "env built only when needed" lazinessTests
    , testGroup "env construction failures" failureTests
    , testGroup "query and output layout" outputTests
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

globalOpts :: Bool -> GlobalOpts
globalOpts remote =
    GlobalOpts
        { goEnvironment = "development"
        , goColor = ColorNever
        , goTheme = ThemeAuto
        , goOutputMode = Nothing
        , goDebug = False
        , goLogFullError = False
        , goRemoteImports = remote
        }

jsonArgs :: Text -> GetImportArgs
jsonArgs loc = GetImportArgs{giaImport = loc, giaFormat = RenderJson, giaQuery = Nothing}

{- | Run get-import with explicit format and query on a local file; also
returns captured stderr-free stdout chunks.
-}
runFormat :: RenderFormat -> Maybe Text -> Text -> IO RunResult
runFormat fmt query loc = do
    out <- newIORef []
    let emit = \case
            OdRawOutput t -> atomicModifyIORef' out (\ts -> (ts <> [t], ()))
            _other -> pure ()
        args = GetImportArgs{giaImport = loc, giaFormat = fmt, giaQuery = query}
    rc <- runGetImportWith (pure (error "env not needed")) emit args (globalOpts False)
    RunResult rc <$> readIORef out <*> pure 0

listFixture :: Text
listFixture = "test-fixtures/get-import/list.yaml"

docFixture :: Text
docFixture = "test-fixtures/get-import/doc.yaml"

-- | Run get-import as JSON, counting env builds and collecting raw output.
runWith :: Bool -> IO Amazonka.Env -> Text -> IO RunResult
runWith remote mkEnv loc = do
    builds <- newIORef (0 :: Int)
    out <- newIORef []
    let countedEnv = bump builds >> mkEnv
        emit = \case
            OdRawOutput t -> atomicModifyIORef' out (\ts -> (ts <> [t], ()))
            _other -> pure ()
    rc <- runGetImportWith countedEnv emit (jsonArgs loc) (globalOpts remote)
    RunResult rc <$> readIORef out <*> readIORef builds

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
