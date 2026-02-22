-- | UpdateStack CloudFormation operation.
--
-- Builds and sends an UpdateStack request, handles the "No updates are to be
-- performed" ValidationError as a success case, polls for completion, collects
-- stack contents, and returns an exit code.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.UpdateStack
  ( updateStack
  ) where

import Control.Exception (try)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Control.Monad.Trans.Resource (runResourceT)

import qualified Amazonka
import qualified Amazonka.CloudFormation.UpdateStack as US

import Iidy.Cfn.Context (CfnContext(..), updateSuccessStates)
import Iidy.Cfn.Operations.DescribeStack (convertEvent, convertStack)
import Iidy.Cfn.RequestBuilder (buildUpdateStackRequest)
import Iidy.Cfn.StackOperations
  ( collectStackContents
  , getStack
  , defaultPollConfig
  , PollConfig(..)
  , getStackId
  , pollForCompletion
  )
import Iidy.Cfn.Types (StackArgs(..))
import Iidy.Output.Types (OutputData(..), StackEventWithTiming(..))

------------------------------------------------------------------------
-- Terminal statuses for update-stack polling
------------------------------------------------------------------------

-- | All terminal stack statuses: polling stops when any of these is reached.
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
  , "DELETE_SKIPPED"
  , "REVIEW_IN_PROGRESS"
  ]

-- | The CloudFormation error message returned when there are no changes to apply.
noUpdatesMessage :: Text
noUpdatesMessage = "No updates are to be performed"

------------------------------------------------------------------------
-- Update stack operation
------------------------------------------------------------------------

-- | Run the update-stack CloudFormation operation.
--
-- Steps:
--   1. Build the UpdateStack request via RequestBuilder.
--   2. Send the request to CloudFormation, catching the "No updates" error.
--   3. On "No updates" ValidationError, return exit code 0 immediately.
--   4. Extract the stack ID from the response (or fall back to DescribeStacks).
--   5. Poll until a terminal status is reached.
--   6. Collect stack contents.
--   7. Return 0 if the final status is in UPDATE_SUCCESS_STATES, 1 otherwise.
updateStack
  :: CfnContext
  -> StackArgs
  -> Maybe FilePath       -- ^ argsfile path for template resolution
  -> Text                 -- ^ environment name
  -> (OutputData -> IO ()) -- ^ output emitter for progress display
  -> IO (Either Text Int)
updateStack ctx args argsfilePath env emit = do
  let stackName = fromMaybe "unnamed-stack" (saStackName args)

  -- Step 1: Build the UpdateStack request (use primary token)
  (req, _token) <- buildUpdateStackRequest ctx args True argsfilePath env

  -- Step 2 & 3: Send the request, catching the "No updates" case
  sendResult <- try (runResourceT $ Amazonka.send (cfnEnv ctx) req)
    :: IO (Either Amazonka.Error US.UpdateStackResponse)

  case sendResult of
    Left awsErr
      | isNoUpdatesError awsErr ->
          -- "No updates are to be performed" is not a real failure
          pure (Right 0)
      | otherwise ->
          pure (Left (T.pack (show awsErr)))

    Right resp -> do
      -- Step 4: Get stack ID (prefer the response, fall back to DescribeStacks)
      mStackId <- case resp.stackId of
        Just sid -> pure (Just sid)
        Nothing  -> getStackId ctx stackName

      let stackId = fromMaybe stackName mStackId
          regionText = Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))

      -- Step 4b: Fetch and emit StackDefinition
      mStack <- getStack ctx stackId
      case mStack of
        Just cfnStack -> emit (OdStackDefinition (convertStack cfnStack regionText) True)
        Nothing -> pure ()

      -- Step 5: Poll for completion, emitting events through renderer
      let pollCfg = defaultPollConfig
            { pcOnNewEvents = \newEvents -> do
                let converted = map (\e -> StackEventWithTiming (convertEvent e) Nothing) newEvents
                emit (OdNewStackEvents converted)
            }
      finalStatus <- pollForCompletion ctx stackId allTerminalStatuses pollCfg

      -- Step 6: Collect and emit stack contents
      contents <- collectStackContents ctx stackName
      emit (OdStackContents contents)

      -- Step 7: Return exit code based on success/failure
      if finalStatus `elem` updateSuccessStates
        then pure (Right 0)
        else pure (Right 1)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Check whether an Amazonka error is the "No updates are to be performed"
-- ValidationError that CloudFormation returns when there are no stack changes.
isNoUpdatesError :: Amazonka.Error -> Bool
isNoUpdatesError (Amazonka.ServiceError se) =
  case se.message of
    Just msg -> noUpdatesMessage `T.isInfixOf` Amazonka.fromErrorMessage msg
    Nothing  -> False
isNoUpdatesError _ = False
