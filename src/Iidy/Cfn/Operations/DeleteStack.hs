-- | DeleteStack CloudFormation operation.
--
-- Checks for stack existence, builds and sends a DeleteStack request,
-- then polls for DELETE_COMPLETE or terminal failure.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.DeleteStack
  ( deleteStack
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Control.Monad.Trans.Resource (runResourceT)

import qualified Amazonka

import Iidy.Aws.Sts (getCallerIdentity)
import Iidy.Cfn.Context (CfnContext(..), deleteSuccessStates)
import Iidy.Cfn.Operations.DescribeStack (convertEventWithDuration, convertStack, buildEventsDisplay)
import Iidy.Cfn.RequestBuilder (buildDeleteStackRequest)
import Iidy.Cfn.StackOperations
  ( collectStackContents
  , defaultPollConfig
  , fetchStackEvents
  , getStack
  , PollConfig(..)
  , getStackId
  , pollForCompletion
  )
import Iidy.Confirm (requestConfirmation)
import Iidy.Output.Types (OutputData(..), StackAbsentInfo(..))

------------------------------------------------------------------------
-- Terminal statuses for delete-stack polling
------------------------------------------------------------------------

-- | All terminal stack statuses relevant to a delete operation.
allTerminalStatuses :: [Text]
allTerminalStatuses =
  [ "DELETE_COMPLETE"
  , "DELETE_FAILED"
  , "CREATE_FAILED"
  , "ROLLBACK_COMPLETE"
  , "ROLLBACK_FAILED"
  , "UPDATE_ROLLBACK_FAILED"
  ]

------------------------------------------------------------------------
-- Delete stack operation
------------------------------------------------------------------------

-- | Run the delete-stack CloudFormation operation.
--
-- Steps:
--   1. Check if the stack exists. If not, return 0 (already deleted).
--   1b. Prompt for confirmation unless --yes flag is set.
--   2. Obtain the stack ARN for reliable polling through deletion.
--   3. Build the DeleteStack request.
--   4. Send the request to CloudFormation.
--   5. Poll until a terminal status is reached, using the stack ID/ARN.
--   6. Return 0 if the final status is DELETE_COMPLETE, 1 otherwise.
--
deleteStack
  :: CfnContext
  -> Text                   -- ^ stack name
  -> Bool                   -- ^ skip confirmation (--yes flag)
  -> Text                   -- ^ environment name
  -> (OutputData -> IO ())  -- ^ output emitter for progress display
  -> IO (Either Text Int)
deleteStack ctx stackName skipConfirmation env emit = do
  let regionText = Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))
  -- Step 1: Check stack existence (fetch full stack for pre-confirmation display)
  mStack <- getStack ctx stackName
  case mStack of
    Nothing -> do
      -- Emit StackAbsentInfo like Rust does
      (account, authArn) <- getCallerIdentity (cfnEnv ctx)
      emit $ OdStackAbsentInfo StackAbsentInfo
        { saiStackName   = stackName
        , saiEnvironment = env
        , saiRegion      = regionText
        , saiAccount     = account
        , saiAuthArn     = authArn
        }
      pure (Right 0)
    Just cfnStack -> do
      -- Step 1a: Show stack definition before confirmation
      emit (OdStackDefinition (convertStack cfnStack regionText) True)

      -- Step 1b: Show previous events and contents before confirmation
      events <- fetchStackEvents ctx stackName
      emit (OdStackEvents (buildEventsDisplay stackName 10 events))
      contents <- collectStackContents ctx stackName
      emit (OdStackContents contents)

      -- Step 1c: Prompt for confirmation unless --yes
      confirmed <- if skipConfirmation
        then pure True
        else requestConfirmation
               ("Are you sure you want to DELETE the stack " <> T.unpack stackName <> "?")
      if not confirmed
        then pure (Right 130)  -- Exit code 130 = user cancelled
        else do
          -- Step 2: Obtain stack ID/ARN for reliable post-delete polling
          mStackId <- getStackId ctx stackName
          let pollTarget = fromMaybe stackName mStackId

          -- Step 3: Build the DeleteStack request
          (req, _token) <- buildDeleteStackRequest ctx stackName

          -- Step 4: Send the DeleteStack request
          _resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

          -- Step 5: Poll for completion, emitting events through renderer
          emit (OdPollingStarted "Loading live events...")
          let pollCfg = defaultPollConfig
                { pcOnNewEvents = \newEvents -> do
                    let converted = map (convertEventWithDuration (cfnStartTime ctx)) newEvents
                    emit (OdNewStackEvents converted)
                , pcOnOperationComplete = \info -> emit (OdOperationComplete info)
                }
          finalStatus <- pollForCompletion ctx pollTarget allTerminalStatuses pollCfg

          -- Step 6: Return exit code based on final status
          if finalStatus `elem` deleteSuccessStates
            then pure (Right 0)
            else pure (Right 1)

