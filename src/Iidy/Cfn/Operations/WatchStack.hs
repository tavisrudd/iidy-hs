-- | Watch-stack CloudFormation operation.
--
-- Observes an in-progress (or recently-completed) stack operation
-- by tailing events until a terminal status is reached.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.WatchStack
  ( watchStack
  ) where

import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Text (Text)

import qualified Amazonka
import qualified Amazonka.CloudFormation.Types as CF

import Iidy.Cfn.Context (CfnContext(..), allTerminalStatuses)
import Iidy.Cfn.Operations.DescribeStack (convertStack, buildEventsDisplay, mkStandardPollConfig)
import Iidy.Cfn.StackOperations
  ( getStack
  , fetchStackEvents
  , collectStackContents
  , pollForCompletion
  , PollConfig(..)
  , PollResult(..)
  )
import Iidy.Output.Types (OutputData(..))

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

      -- 3. Get stable stack ID (from already-fetched stack, no extra API call)
      let sId = fromMaybe stackName cfnStack.stackId

      -- 4. Fetch and emit previous events
      initialEvents <- fetchStackEvents ctx sId
      let prevEventsDisplay = buildEventsDisplay 10 initialEvents
      emit (OdStackEvents prevEventsDisplay)
      let seenIds = Set.fromList (map (.eventId) initialEvents)

      -- 5. Poll until terminal status, emitting live events
      emit (OdPollingStarted "Loading live events...")
      let baseCfg = mkStandardPollConfig ctx emit
          pollCfg = baseCfg
            { pcWaitForStatusChange    = True
            , pcInactivityTimeoutSecs  = if timeoutSeconds > 0 then Just timeoutSeconds else Nothing
            , pcOnNewEvents            = \newEvents -> do
                -- Second dedup layer: filter events seen before polling started
                let fresh = filter (\e -> Set.notMember e.eventId seenIds) newEvents
                pcOnNewEvents baseCfg fresh
            , pcOnInactivityTimeout    = \info -> emit (OdInactivityTimeout info)
            }
      pollResult <- pollForCompletion ctx sId allTerminalStatuses pollCfg

      -- 6. If DELETE_COMPLETE, nothing more to collect; otherwise collect contents.
      -- All non-DELETE_COMPLETE results — including PollInactivityTimeout — return
      -- exit code 0 because watch-stack is observational: it does not start the
      -- operation, so it cannot "fail" when one stalls. Callers that need to
      -- distinguish timeout from completion should check the OdInactivityTimeout
      -- event emitted by pcOnInactivityTimeout above.
      case pollResult of
        PollSuccess "DELETE_COMPLETE" -> pure (Right 0)
        _ -> do
          contents <- collectStackContents ctx stackName
          emit (OdStackContents contents)
          pure (Right 0)

