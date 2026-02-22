-- | Core stack operations: fetching, event polling, content collection.
--
-- Provides building blocks used by individual CFN operations.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.StackOperations
  ( -- * Stack info
    getStack
  , getStackId
  , stackExists
    -- * Events
  , fetchStackEvents
    -- * Content collection
  , collectStackContents
    -- * Event polling
  , pollForCompletion
  , pollForCompletionWith
  , PollConfig(..)
  , defaultPollConfig
    -- * Helpers (exported for testing)
  , stackNameFromId
  ) where

import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import qualified Amazonka
import qualified Amazonka.CloudFormation as CF
import qualified Amazonka.CloudFormation.Types as CF
-- Import operation modules with unique qualifiers for unambiguous record fields
import qualified Amazonka.CloudFormation.DescribeStacks as DStacks
import qualified Amazonka.CloudFormation.DescribeStackEvents as DEvents
import qualified Amazonka.CloudFormation.DescribeStackResources as DRes
import qualified Amazonka.CloudFormation.ListChangeSets as LCS

import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Output.Types

------------------------------------------------------------------------
-- Stack info
------------------------------------------------------------------------

-- | Get a stack by name. Returns Nothing if stack doesn't exist.
getStack :: CfnContext -> Text -> IO (Maybe CF.Stack)
getStack ctx stackName = do
  let req = DStacks.newDescribeStacks
              { DStacks.stackName = Just stackName }
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req
  pure $ case resp.stacks of
    Just (s:_) -> Just s
    _          -> Nothing

-- | Get stack ID from stack name.
getStackId :: CfnContext -> Text -> IO (Maybe Text)
getStackId ctx sName = do
  mStack <- getStack ctx sName
  pure $ mStack >>= (.stackId)

-- | Check if a stack exists (and is not in DELETE_COMPLETE state)
stackExists :: CfnContext -> Text -> IO Bool
stackExists ctx sName = do
  mStack <- getStack ctx sName
  pure $ case mStack of
    Nothing -> False
    Just s  -> s.stackStatus /= CF.StackStatus_DELETE_COMPLETE

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

-- | Fetch stack events (most recent first)
fetchStackEvents :: CfnContext -> Text -> IO [CF.StackEvent]
fetchStackEvents ctx sId = do
  let req = DEvents.newDescribeStackEvents
              { DEvents.stackName = Just sId }
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req
  pure $ fromMaybe [] resp.stackEvents

------------------------------------------------------------------------
-- Content collection
------------------------------------------------------------------------

-- | Collect full stack contents (resources, outputs, exports, status, changesets)
collectStackContents :: CfnContext -> Text -> IO StackContents
collectStackContents ctx sName = do
  -- Fetch resources
  let resReq = DRes.newDescribeStackResources
                 { DRes.stackName = Just sName }
  resourcesResp <- runResourceT $ Amazonka.send (cfnEnv ctx) resReq
  let resources = mapMaybe convertResource (fromMaybe [] resourcesResp.stackResources)

  -- Fetch stack for outputs and status
  mStack <- getStack ctx sName
  let outputs = case mStack of
        Nothing -> []
        Just s  -> mapMaybe convertOutput (fromMaybe [] s.outputs)
      statusInfo = case mStack of
        Nothing -> StackStatusInfo "UNKNOWN" Nothing Nothing
        Just s  -> StackStatusInfo
          { ssiStatus = CF.fromStackStatus s.stackStatus
          , ssiStatusReason = s.stackStatusReason
          , ssiTimestamp = Nothing
          }

  -- Fetch pending changesets
  changesetsResp <- runResourceT $ Amazonka.send (cfnEnv ctx) $
    LCS.newListChangeSets sName
  let changesets = mapMaybe convertChangeSetSummary (fromMaybe [] changesetsResp.summaries)

  pure StackContents
    { scResources = resources
    , scOutputs = outputs
    , scExports = []  -- Exports require separate ListExports call
    , scCurrentStatus = statusInfo
    , scPendingChangesets = changesets
    }

------------------------------------------------------------------------
-- Event polling
------------------------------------------------------------------------

data PollConfig = PollConfig
  { pcIntervalSeconds :: !Int
  , pcTimeoutSeconds  :: !(Maybe Int)
  , pcOnNewEvents     :: [CF.StackEvent] -> IO ()
  }

defaultPollConfig :: PollConfig
defaultPollConfig = PollConfig
  { pcIntervalSeconds = 2
  , pcTimeoutSeconds = Nothing
  , pcOnNewEvents = const (pure ())
  }

-- | Poll for stack operation completion.
-- Returns the final stack status.
pollForCompletion
  :: CfnContext
  -> Text          -- ^ stack ID (use ID not name for deletes)
  -> [Text]        -- ^ terminal status strings
  -> PollConfig
  -> IO Text       -- ^ final status
pollForCompletion ctx sId = pollForCompletionWith (fetchStackEvents ctx sId) sId

-- | Testable polling loop — takes an event-fetching action instead of CfnContext.
pollForCompletionWith
  :: IO [CF.StackEvent]  -- ^ event fetcher
  -> Text                -- ^ stack ID (for isStackEvent check)
  -> [Text]              -- ^ terminal status strings
  -> PollConfig
  -> IO Text             -- ^ final status
pollForCompletionWith fetchEvents sId terminalStatuses config = go []
  where
    go :: [Text] -> IO Text
    go lastEventIds = do
      threadDelay (pcIntervalSeconds config * 1000000)
      events <- fetchEvents
      -- Filter to new events only
      let newEvents = filter (\e -> e.eventId `notElem` lastEventIds) events
      when (not (null newEvents)) $
        pcOnNewEvents config (reverse newEvents)
      -- Check if we hit a terminal status (on the stack itself, not nested resources)
      let stackEvents = filter isStackEvent events
          currentStatus = case stackEvents of
            (e:_) -> maybe "" CF.fromResourceStatus e.resourceStatus
            _     -> ""
      if currentStatus `elem` terminalStatuses
        then pure currentStatus
        else go (map (.eventId) events)

    isStackEvent :: CF.StackEvent -> Bool
    isStackEvent e =
      e.logicalResourceId == Just (stackNameFromId sId)
      || e.resourceType == Just "AWS::CloudFormation::Stack"

-- | Extract stack name from a stack ID (ARN format: arn:.../stackName/guid)
stackNameFromId :: Text -> Text
stackNameFromId sid = case T.splitOn "/" sid of
  (_:name:_) -> name
  _          -> sid

------------------------------------------------------------------------
-- AWS type conversion helpers
------------------------------------------------------------------------

convertResource :: CF.StackResource -> Maybe StackResourceInfo
convertResource r = Just StackResourceInfo
  { sriLogicalResourceId = r.logicalResourceId
  , sriPhysicalResourceId = r.physicalResourceId
  , sriResourceType = r.resourceType
  , sriResourceStatus = CF.fromResourceStatus r.resourceStatus
  , sriResourceStatusReason = r.resourceStatusReason
  , sriLastUpdated = Nothing
  }

convertOutput :: CF.Output -> Maybe StackOutputInfo
convertOutput o = do
  key <- o.outputKey
  pure StackOutputInfo
    { soiOutputKey = key
    , soiOutputValue = fromMaybe "" o.outputValue
    , soiDescription = o.description
    , soiExportName = o.exportName
    }

convertChangeSetSummary :: CF.ChangeSetSummary -> Maybe ChangeSetInfo
convertChangeSetSummary cs = do
  name <- cs.changeSetName
  csId <- cs.changeSetId
  pure ChangeSetInfo
    { csiChangeSetName = name
    , csiChangeSetId = csId
    , csiStackId = fromMaybe "" cs.stackId
    , csiStackName = fromMaybe "" cs.stackName
    , csiDescription = cs.description
    , csiStatus = maybe "" CF.fromChangeSetStatus cs.status
    , csiStatusReason = cs.statusReason
    , csiCreationTime = Nothing
    , csiExecutionStatus = CF.fromExecutionStatus <$> cs.executionStatus
    , csiChanges = []
    }
