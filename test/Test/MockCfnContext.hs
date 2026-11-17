{- | A 'CfnContext' over a mock AWS env ('Test.MockAws'), for tests of
CloudFormation and template-approval operations. Emitted 'OutputData' is
collected in order instead of being rendered.
-}
module Test.MockCfnContext (
    MockCfn (..),
    newMockCfnContext,
    mockCfnOutputs,
    mockCfnTime,
) where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))

import Iidy.Aws.ClientReqToken (TokenInfo (..), TokenSource (..))
import Iidy.Aws.CredentialSource (CredentialSourceStack (..))
import Iidy.Aws.Timing (mockTimeProvider)
import Iidy.Cfn.Context (CfnContext, createContextFromEnv)
import Iidy.Cfn.Types (CfnOperation)
import Iidy.Output.Types (OutputData)
import Iidy.Yaml.Imports.Types (RemoteImports (..))
import Test.MockAws (MockAws (..))

-- | A context over a mock env and the outputs it has emitted.
data MockCfn = MockCfn
    { mcContext :: !CfnContext
    , mcOutputs :: !(IORef [OutputData])
    }

-- | The fixed time the context's time provider reports.
mockCfnTime :: UTCTime
mockCfnTime = UTCTime (fromGregorian 2026 1 1) 0

{- | Build a context for an operation and an environment name (the
@--environment@ value) over the mock's env. Remote imports are blocked and
the credential source stack is empty.
-}
newMockCfnContext :: MockAws -> CfnOperation -> Text -> IO MockCfn
newMockCfnContext mock operation environment = do
    outputs <- newIORef []
    let emit od = atomicModifyIORef' outputs (\ods -> (ods <> [od], ()))
        token = TokenInfo "mock-token" UserProvided "mock-operation"
    ctx <-
        createContextFromEnv
            (mockEnv mock)
            (CredentialSourceStack [])
            operation
            (mockTimeProvider mockCfnTime)
            token
            environment
            BlockRemoteImports
            emit
    pure MockCfn{mcContext = ctx, mcOutputs = outputs}

-- | The outputs emitted so far, in order.
mockCfnOutputs :: MockCfn -> IO [OutputData]
mockCfnOutputs = readIORef . mcOutputs
