-- | Watch-stack CloudFormation operation.
--
-- Observes an in-progress (or recently-completed) stack operation
-- by tailing events until a terminal status is reached.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.WatchStack
  ( watchStack
  , formatEvent
  , allTerminalStatuses
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import qualified Amazonka
import qualified Amazonka.CloudFormation as CF
import qualified Amazonka.CloudFormation.Types as CF

import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.Operations.DescribeStack (convertStack, convertEventWithDuration, buildEventsDisplay)
import Iidy.Cfn.StackOperations
  ( getStack
  , getStackId
  , fetchStackEvents
  , collectStackContents
  , pollForCompletion
  , PollConfig(..)
  , defaultPollConfig
  )
import Iidy.Output.Types (OutputData(..))

------------------------------------------------------------------------
-- Terminal statuses
------------------------------------------------------------------------

-- | All terminal CloudFormation stack statuses.
allTerminalStatuses :: [Text]
allTerminalStatuses =
  [ "CREATE_COMPLETE", "CREATE_FAILED"
  , "DELETE_COMPLETE", "DELETE_FAILED"
  , "ROLLBACK_COMPLETE", "ROLLBACK_FAILED"
  , "UPDATE_COMPLETE", "UPDATE_FAILED"
  , "UPDATE_ROLLBACK_COMPLETE", "UPDATE_ROLLBACK_FAILED"
  , "IMPORT_COMPLETE", "IMPORT_ROLLBACK_COMPLETE", "IMPORT_ROLLBACK_FAILED"
  ]

------------------------------------------------------------------------
-- Main entry point
------------------------------------------------------------------------

-- | Watch a CloudFormation stack operation until it reaches a terminal state.
--
-- Polls for events and calls the callback with each batch of new events.
-- Returns @Right 0@ when watching completes (regardless of the final status,
-- since watch merely observes).  Returns @Left err@ if the stack is not found.
watchStack
  :: CfnContext
  -> Text                    -- ^ stack name
  -> Int                     -- ^ inactivity timeout in seconds
  -> (OutputData -> IO ())   -- ^ output emitter
  -> IO (Either Text Int)
watchStack ctx stackName timeoutSeconds emit = do
  -- 1. Verify stack exists
  mStack <- getStack ctx stackName
  case mStack of
    Nothing ->
      pure $ Left ("Stack not found: " <> stackName)
    Just cfnStack -> do
      -- 2. Emit StackDefinition
      let regionText = Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))
          stackDef = convertStack cfnStack regionText
      emit (OdStackDefinition stackDef True)

      -- 3. Get stable stack ID
      mStackId <- getStackId ctx stackName
      let sId = fromMaybe stackName mStackId

      -- 4. Fetch and emit previous events
      initialEvents <- fetchStackEvents ctx sId
      let prevEventsDisplay = buildEventsDisplay stackName 10 initialEvents
      emit (OdStackEvents prevEventsDisplay)
      let seenIds = map (.eventId) initialEvents

      -- 5. Poll until terminal status, emitting live events
      emit (OdPollingStarted "Loading live events...")
      let pollCfg = defaultPollConfig
            { pcWaitForStatusChange = True
            , pcInactivityTimeoutSecs = if timeoutSeconds > 0 then Just timeoutSeconds else Nothing
            , pcOnNewEvents = \newEvents -> do
                let fresh = filter (\e -> e.eventId `notElem` seenIds) newEvents
                if null fresh then pure ()
                else do
                  let converted = map (convertEventWithDuration (cfnStartTime ctx)) fresh
                  emit (OdNewStackEvents converted)
            , pcOnOperationComplete = \info -> emit (OdOperationComplete info)
            , pcOnInactivityTimeout = \info -> emit (OdInactivityTimeout info)
            }
      finalStatus <- pollForCompletion ctx sId allTerminalStatuses pollCfg

      -- 6. If DELETE_COMPLETE, nothing more to collect; otherwise collect contents
      if finalStatus == "DELETE_COMPLETE"
        then pure (Right 0)
        else do
          contents <- collectStackContents ctx stackName
          emit (OdStackContents contents)
          pure (Right 0)

------------------------------------------------------------------------
-- Event formatting
------------------------------------------------------------------------

-- | Format a stack event as a human-readable summary line.
formatEvent :: CF.StackEvent -> Text
formatEvent e =
  T.intercalate " | "
    [ fromMaybe "" e.logicalResourceId
    , fromMaybe "" e.resourceType
    , maybe "" CF.fromResourceStatus e.resourceStatus
    , fromMaybe "" e.resourceStatusReason
    ]
