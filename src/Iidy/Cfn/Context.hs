-- | CloudFormation operation context.
--
-- CfnContext holds the AWS clients, credential provenance, timing,
-- and token management needed for CloudFormation operations.
module Iidy.Cfn.Context
  ( CfnContext(..)
  , createContext
  , createContextFromEnv
  , ctxElapsedSeconds
  , ctxDeriveToken
  , ctxGetUsedTokens
    -- * Success state helpers
  , createSuccessStates
  , updateSuccessStates
  , deleteSuccessStates
    -- * Terminal status helpers
  , allTerminalStatuses
  , createTerminalStatuses
  , updateTerminalStatuses
  , deleteTerminalStatuses
  , changesetTerminalStatuses
  ) where

import Data.IORef
import Data.Text (Text)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)

import qualified Amazonka

import Iidy.Aws.ClientReqToken (TokenInfo(..), deriveTokenForStep)
import Iidy.Aws.Config (createAwsEnvFromSettings)
import Iidy.Aws.CredentialSource (AwsSettings(..), CredentialSourceStack)
import Iidy.Aws.Timing (TimeProvider(..))
import Iidy.Cfn.Status (StackStatus(..))
import qualified Iidy.Cfn.Status as Status
import Iidy.Cfn.Types (CfnOperation)

------------------------------------------------------------------------
-- Context type
------------------------------------------------------------------------

data CfnContext = CfnContext
  { cfnEnv               :: !Amazonka.Env
  , cfnCredentialSources :: !CredentialSourceStack
  , cfnTimeProvider      :: !TimeProvider
  , cfnStartTime         :: !UTCTime
  , cfnPrimaryToken      :: !TokenInfo
  , cfnUsedTokens        :: !(IORef [TokenInfo])
  , cfnOperation         :: !CfnOperation
  }

------------------------------------------------------------------------
-- Creation
------------------------------------------------------------------------

-- | Create a CfnContext from AWS settings and operation info.
createContext :: AwsSettings -> CfnOperation -> TimeProvider -> TokenInfo -> IO CfnContext
createContext settings operation tp token = do
  (env, credStack) <- createAwsEnvFromSettings settings
  createContextFromEnv env credStack operation tp token

-- | Create a CfnContext from an already-configured Env.
-- Used when the AWS config has already been set up (e.g., during stack-args loading).
createContextFromEnv
  :: Amazonka.Env
  -> CredentialSourceStack
  -> CfnOperation
  -> TimeProvider
  -> TokenInfo
  -> IO CfnContext
createContextFromEnv env credStack operation tp token = do
  startTime <- tpStartTime tp
  tokenRef <- newIORef [token]
  pure CfnContext
    { cfnEnv               = env
    , cfnCredentialSources = credStack
    , cfnTimeProvider      = tp
    , cfnStartTime         = startTime
    , cfnPrimaryToken      = token
    , cfnUsedTokens        = tokenRef
    , cfnOperation         = operation
    }

------------------------------------------------------------------------
-- Operations
------------------------------------------------------------------------

-- | Get elapsed seconds since operation start
ctxElapsedSeconds :: CfnContext -> IO Int
ctxElapsedSeconds ctx = do
  now <- getCurrentTime
  pure $ round (diffUTCTime now (cfnStartTime ctx))

-- | Derive a token for a specific step and track it
ctxDeriveToken :: CfnContext -> Text -> IO TokenInfo
ctxDeriveToken ctx step = do
  let derived = deriveTokenForStep (cfnPrimaryToken ctx) step
  modifyIORef' (cfnUsedTokens ctx) (derived :)
  pure derived

-- | Get all tokens used during this operation
ctxGetUsedTokens :: CfnContext -> IO [TokenInfo]
ctxGetUsedTokens ctx = reverse <$> readIORef (cfnUsedTokens ctx)

------------------------------------------------------------------------
-- Success state helpers
------------------------------------------------------------------------

createSuccessStates :: [StackStatus]
createSuccessStates = [CreateComplete]

updateSuccessStates :: [StackStatus]
updateSuccessStates = [UpdateComplete]

deleteSuccessStates :: [StackStatus]
deleteSuccessStates = [DeleteComplete]

------------------------------------------------------------------------
-- Terminal status helpers
------------------------------------------------------------------------

-- | All terminal stack statuses. Delegates to the canonical definition
-- in Iidy.Cfn.Status (derived from the StackStatus ADT).
allTerminalStatuses :: [StackStatus]
allTerminalStatuses = Status.allTerminalStatuses

-- | Terminal statuses for create-stack polling.
createTerminalStatuses :: [StackStatus]
createTerminalStatuses = allTerminalStatuses

-- | Terminal statuses for update-stack polling.
updateTerminalStatuses :: [StackStatus]
updateTerminalStatuses = allTerminalStatuses

-- | Terminal statuses for delete-stack polling.
deleteTerminalStatuses :: [StackStatus]
deleteTerminalStatuses = allTerminalStatuses

-- | Terminal statuses for changeset execution polling.
changesetTerminalStatuses :: [StackStatus]
changesetTerminalStatuses = allTerminalStatuses
