-- | CloudFormation changeset operations: create, execute, describe.
--
-- Provides createChangeset, executeChangeset, and describeChangeset,
-- which correspond to the CloudFormation CreateChangeSet, ExecuteChangeSet,
-- and DescribeChangeSet API calls respectively.
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.Changeset
  ( createChangeset
  , executeChangeset
  , describeChangeset
  -- * Internal (exported for testing)
  , convertChange
  , convertDetail
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (catch)
import Control.Lens (set, view)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import qualified Amazonka
import qualified Amazonka.CloudFormation as CF
import qualified Amazonka.CloudFormation.Types as CF
import qualified Amazonka.CloudFormation.CreateChangeSet as CCS
import qualified Amazonka.CloudFormation.ExecuteChangeSet as ECS
import qualified Amazonka.CloudFormation.DescribeChangeSet as DCS

import Iidy.Aws.ClientReqToken (TokenInfo(..))
import Iidy.Cfn.Context
  ( CfnContext(..)
  , createSuccessStates
  , updateSuccessStates
  , ctxDeriveToken
  )
import Iidy.Cfn.RequestBuilder (buildCreateChangeSetRequest)
import Iidy.Cfn.Operations.DescribeStack (convertEvent)
import Iidy.Cfn.StackOperations
  ( defaultPollConfig
  , PollConfig(..)
  , getStackId
  , pollForCompletion
  )
import Iidy.Cfn.Types (StackArgs(..))
import Iidy.Output.Types
  ( OutputData(..), StackEventWithTiming(..)
  , ChangeSetInfo(..), ChangeInfo(..), ChangeDetail(..)
  )

------------------------------------------------------------------------
-- Terminal statuses for post-execute stack polling
------------------------------------------------------------------------

-- | All terminal stack statuses used when polling after ExecuteChangeSet.
allTerminalStatuses :: [Text]
allTerminalStatuses =
  [ "CREATE_COMPLETE"
  , "ROLLBACK_COMPLETE"
  , "DELETE_COMPLETE"
  , "UPDATE_COMPLETE"
  , "UPDATE_ROLLBACK_COMPLETE"
  , "IMPORT_COMPLETE"
  , "IMPORT_ROLLBACK_COMPLETE"
  , "CREATE_FAILED"
  , "DELETE_FAILED"
  , "ROLLBACK_FAILED"
  , "UPDATE_ROLLBACK_FAILED"
  , "IMPORT_ROLLBACK_FAILED"
  ]

------------------------------------------------------------------------
-- Changeset creation
------------------------------------------------------------------------

-- | Create a CloudFormation change set, poll until it reaches a terminal
-- state, then return the ChangeSetInfo.
--
-- Steps:
--   1. Build the CreateChangeSet request (type = CREATE or UPDATE based on stackExists).
--   2. Send it.
--   3. Extract the changeset ID from the response.
--   4. Poll DescribeChangeSet every 2s until status is CREATE_COMPLETE or FAILED.
--   5. Return the final ChangeSetInfo.
createChangeset
  :: CfnContext
  -> StackArgs
  -> Text            -- ^ changeset name
  -> Bool            -- ^ stack exists? (True => UPDATE, False => CREATE type)
  -> Maybe FilePath  -- ^ argsfile path for template resolution
  -> Text            -- ^ environment name
  -> IO (Either Text ChangeSetInfo)
createChangeset ctx args csName stackExists argsfilePath env = do
  let csType = if stackExists
                 then CF.ChangeSetType_UPDATE
                 else CF.ChangeSetType_CREATE
      stackName = fromMaybe "unnamed-stack" (saStackName args)

  -- Step 1 & 2: Build and send the CreateChangeSet request
  (req, _token) <- buildCreateChangeSetRequest ctx args csName csType argsfilePath env
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

  -- Step 3: Extract the changeset ARN/ID (fall back to name for polling).
  -- OverloadedRecordDot cannot be used for 'id' (conflicts with Prelude.id);
  -- use the generated lens accessor instead.
  let csId = fromMaybe csName (view CCS.createChangeSetResponse_id resp)

  -- Step 4: Poll until CREATE_COMPLETE or FAILED
  finalInfo <- pollChangesetCompletion ctx stackName csId

  pure (Right finalInfo)

-- | Poll DescribeChangeSet every 2s until the changeset reaches a terminal
-- state (CREATE_COMPLETE or FAILED).  Returns the ChangeSetInfo on completion.
pollChangesetCompletion :: CfnContext -> Text -> Text -> IO ChangeSetInfo
pollChangesetCompletion ctx stackName csId = go
  where
    go :: IO ChangeSetInfo
    go = do
      threadDelay (2 * 1000000)  -- 2 seconds
      result <- describeChangesetRaw ctx stackName csId
      case result of
        Left _    -> go   -- transient error: keep polling
        Right info ->
          if isTerminalCsStatus (csiStatus info)
            then pure info
            else go

    isTerminalCsStatus :: Text -> Bool
    isTerminalCsStatus s = s `elem` ["CREATE_COMPLETE", "FAILED", "DELETE_COMPLETE", "DELETE_FAILED"]

------------------------------------------------------------------------
-- Changeset execution
------------------------------------------------------------------------

-- | Execute a CloudFormation change set and poll the stack for completion.
--
-- Steps:
--   1. Build and send ExecuteChangeSet.
--   2. Get the stack ID for polling.
--   3. Poll for completion; both CREATE_COMPLETE and UPDATE_COMPLETE are success states.
--   4. Return exit code (0 = success, 1 = failure).
executeChangeset
  :: CfnContext
  -> Text                   -- ^ stack name
  -> Text                   -- ^ changeset name
  -> (OutputData -> IO ())  -- ^ output emitter for progress display
  -> IO (Either Text Int)
executeChangeset ctx stackName csName emit = do
  -- Step 1: Build and send ExecuteChangeSet request
  token <- ctxDeriveToken ctx "execute-changeset"
  let baseReq = ECS.newExecuteChangeSet csName
      req = baseReq
        { ECS.stackName           = Just stackName
        , ECS.clientRequestToken  = Just (tiValue token)
        }
  _resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

  -- Step 2: Get stack ID for polling
  mStackId <- getStackId ctx stackName
  let stackId = fromMaybe stackName mStackId

  -- Step 3: Poll for completion, emitting events through renderer
  let pollCfg = defaultPollConfig
        { pcOnNewEvents = \newEvents -> do
            let converted = map (\e -> StackEventWithTiming (convertEvent e) Nothing) newEvents
            emit (OdNewStackEvents converted)
        }
  finalStatus <- pollForCompletion ctx stackId allTerminalStatuses pollCfg

  -- Step 4: Return exit code
  let successStates = createSuccessStates ++ updateSuccessStates
  if finalStatus `elem` successStates
    then pure (Right 0)
    else pure (Right 1)

------------------------------------------------------------------------
-- Changeset description
------------------------------------------------------------------------

-- | Describe a CloudFormation change set and return its ChangeSetInfo.
describeChangeset
  :: CfnContext
  -> Text  -- ^ stack name
  -> Text  -- ^ changeset name
  -> IO (Either Text ChangeSetInfo)
describeChangeset ctx stackName csName =
  describeChangesetRaw ctx stackName csName

------------------------------------------------------------------------
-- Internal: raw DescribeChangeSet call
------------------------------------------------------------------------

-- | Call DescribeChangeSet and convert the response to ChangeSetInfo.
-- Returns Left on Amazonka errors.
describeChangesetRaw
  :: CfnContext
  -> Text  -- ^ stack name
  -> Text  -- ^ changeset name (or ARN)
  -> IO (Either Text ChangeSetInfo)
describeChangesetRaw ctx stackName csName = do
  let req = set DCS.describeChangeSet_stackName (Just stackName)
              (DCS.newDescribeChangeSet csName)
  result <- fmap Right (runResourceT $ Amazonka.send (cfnEnv ctx) req)
    `catch` (\e -> pure (Left (T.pack (show (e :: Amazonka.Error)))))
  case result of
    Left err   -> pure (Left err)
    Right resp -> pure (Right (convertDescribeResponse resp))

-- | Convert a DescribeChangeSetResponse to ChangeSetInfo.
convertDescribeResponse :: DCS.DescribeChangeSetResponse -> ChangeSetInfo
convertDescribeResponse resp = ChangeSetInfo
  { csiChangeSetName   = fromMaybe "" resp.changeSetName
  , csiChangeSetId     = fromMaybe "" resp.changeSetId
  , csiStackId         = fromMaybe "" resp.stackId
  , csiStackName       = fromMaybe "" resp.stackName
  , csiDescription     = resp.description
  , csiStatus          = CF.fromChangeSetStatus resp.status
  , csiStatusReason    = resp.statusReason
  , csiCreationTime    = Nothing  -- creationTime is ISO8601, skip for now
  , csiExecutionStatus = CF.fromExecutionStatus <$> resp.executionStatus
  , csiChanges         = mapMaybe convertChange (fromMaybe [] resp.changes)
  }

------------------------------------------------------------------------
-- AWS type conversion helpers
------------------------------------------------------------------------

-- | Convert a CF.Change to ChangeInfo (returns Nothing if resourceChange absent).
convertChange :: CF.Change -> Maybe ChangeInfo
convertChange ch = do
  rc <- ch.resourceChange
  logId <- rc.logicalResourceId
  rType <- rc.resourceType
  pure ChangeInfo
    { ciAction             = maybe "" CF.fromChangeAction rc.action
    , ciLogicalResourceId  = logId
    , ciPhysicalResourceId = rc.physicalResourceId
    , ciResourceType       = rType
    , ciReplacement        = CF.fromReplacement <$> rc.replacement
    , ciScope              = fmap (map CF.fromResourceAttribute) rc.scope
    , ciDetails            = mapMaybe convertDetail (fromMaybe [] rc.details)
    }

-- | Convert a CF.ResourceChangeDetail to ChangeDetail.
convertDetail :: CF.ResourceChangeDetail -> Maybe ChangeDetail
convertDetail d =
  let targetText = case d.target of
        Nothing -> ""
        Just t  -> fromMaybe "" (fmap CF.fromResourceAttribute t.attribute)
  in Just ChangeDetail
       { cdTarget        = targetText
       , cdEvaluation    = CF.fromEvaluationType <$> d.evaluation
       , cdChangeSource  = CF.fromChangeSource <$> d.changeSource
       , cdCausingEntity = d.causingEntity
       }
