{- | Tests for the AWS environment that stack-args imports run under
('loadStackArgsBootstrapped'), against the in-process mock AWS.
-}
module Test.StackArgsBootstrapTest (stackArgsBootstrapTests) where

import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Aws.CredentialSource (AwsSettings (..))
import Iidy.Cfn.StackArgsBootstrap (loadStackArgsBootstrapped)
import Iidy.Cfn.StackArgsLoader (LoadedStackArgs (..))
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..))
import Iidy.Yaml.Imports.Types (RemoteImports (..))
import Test.MockAws (MockAws (..), newMockAws, recordingEnvFactory)
import Test.Shared (noAwsSettings)

stackArgsBootstrapTests :: [TestTree]
stackArgsBootstrapTests =
    [ testCase "literal Profile and Region with an ssm: import load under those literals" $ do
        run <- loadWithMock noAwsSettings "literal-ssm.yaml"
        loaded <- expectRight (bsResult run)
        bsAsked run @?= [AwsSettings (Just "literal-profile") (Just "eu-west-1") Nothing]
        bsServed run @?= ["ssm.GetParameter.json"]
        saParameters (lsaStackArgs loaded) @?= Just (Map.fromList [("DbHost", "db.internal.example")])
    ]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | What one load did: its result, the factory calls, the mock requests.
data BootstrapRun = BootstrapRun
    { bsResult :: !(Either Text LoadedStackArgs)
    , bsAsked :: ![AwsSettings]
    , bsServed :: ![FilePath]
    }

-- | Load a fixture with the given CLI settings and a recording mock factory.
loadWithMock :: AwsSettings -> FilePath -> IO BootstrapRun
loadWithMock cliAws fixture = do
    mock <- newMockAws
    (factory, askedFor) <- recordingEnvFactory mock
    result <- loadStackArgsBootstrapped factory (fixturePath fixture) "dev" OpCreateStack cliAws AllowRemoteImports
    BootstrapRun result <$> askedFor <*> readIORef (mockRequests mock)

fixturePath :: FilePath -> FilePath
fixturePath name = "test-fixtures/stack-args-bootstrap/" <> name

expectRight :: Either Text a -> IO a
expectRight = either (assertFailure . ("expected the load to succeed: " <>) . T.unpack) pure
