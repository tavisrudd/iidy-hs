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

import qualified Amazonka.CloudFormation as CF
import qualified Amazonka.CloudFormation.Types as CF

import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.StackOperations
  ( getStack
  , getStackId
  , fetchStackEvents
  , collectStackContents
  , pollForCompletion
  , PollConfig(..)
  , defaultPollConfig
  )

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
-- Polls for events and calls the callback with formatted event summaries.
-- Returns @Right 0@ when watching completes (regardless of the final status,
-- since watch merely observes).  Returns @Left err@ if the stack is not found.
watchStack
  :: CfnContext
  -> Text           -- ^ stack name
  -> Int            -- ^ inactivity timeout in seconds
  -> (Text -> IO ()) -- ^ callback for new events (event summary text)
  -> IO (Either Text Int)
watchStack ctx stackName _timeoutSeconds onEvent = do
  -- 1. Verify stack exists
  mStack <- getStack ctx stackName
  case mStack of
    Nothing ->
      pure $ Left ("Stack not found: " <> stackName)
    Just _ -> do
      -- 2. Get stable stack ID (use ID for deletes so we keep tracking after name gone)
      mStackId <- getStackId ctx stackName
      let sId = fromMaybe stackName mStackId

      -- 3. Fetch initial events to mark as already-seen
      initialEvents <- fetchStackEvents ctx sId
      let seenIds = map (.eventId) initialEvents

      -- 4. Poll until terminal status, firing callback for each new event batch
      let pollCfg = defaultPollConfig
            { pcOnNewEvents = \newEvents ->
                mapM_ (onEvent . formatEvent) newEvents
            }
      finalStatus <- pollForCompletion ctx sId allTerminalStatuses pollCfg { pcOnNewEvents = \newEvents -> do
          -- Filter out already-seen events (first call may overlap with initial fetch)
          let fresh = filter (\e -> e.eventId `notElem` seenIds) newEvents
          mapM_ (onEvent . formatEvent) fresh
        }

      -- 5. If DELETE_COMPLETE, nothing more to collect; otherwise collect contents
      if finalStatus == "DELETE_COMPLETE"
        then pure (Right 0)
        else do
          _ <- collectStackContents ctx stackName
          -- 6. Watch just observes — always return 0
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
