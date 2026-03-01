-- | CreateStack CloudFormation operation.
--
-- Builds and sends a CreateStack request, polls for completion,
-- collects stack contents, and returns an exit code.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.CreateStack
  ( createStack
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Control.Monad.Trans.Resource (runResourceT)

import qualified Amazonka
import qualified Amazonka.CloudFormation.CreateStack as CS

import Iidy.Cfn.Context (CfnContext(..), createSuccessStates, createTerminalStatuses)
import Iidy.Cfn.Operations.DescribeStack (convertEventWithDuration, convertStack)
import Iidy.Cfn.RequestBuilder (buildCreateStackRequest)
import Iidy.Cfn.StackOperations
  ( collectStackContents
  , getStack
  , defaultPollConfig
  , PollConfig(..)
  , pollForCompletion
  , PollResult(..)
  )
import Iidy.Cfn.Types (StackArgs(..), getStackName)
import Iidy.Output.Types (OutputData(..))

------------------------------------------------------------------------
-- Create stack operation
------------------------------------------------------------------------

-- | Run the create-stack CloudFormation operation.
--
-- Steps:
--   1. Build the CreateStack request via RequestBuilder.
--   2. Send the request to CloudFormation.
--   3. Extract the new stack ID from the response.
--   4. Poll until a terminal status is reached, emitting events.
--   5. On DELETE_COMPLETE, return exit code 1 (stack was rolled back and deleted).
--   6. Collect stack contents for display.
--   7. Return 0 if the final status is in CREATE_SUCCESS_STATES, 1 otherwise.
createStack
  :: CfnContext
  -> StackArgs
  -> Maybe FilePath       -- ^ argsfile path for template resolution
  -> Text                 -- ^ environment name
  -> (OutputData -> IO ()) -- ^ output emitter for progress display
  -> IO (Either Text Int)
createStack ctx args argsfilePath env emit = do
  -- Step 1: Build the request (use primary token for create)
  (req, _token) <- buildCreateStackRequest ctx args True argsfilePath env

  -- Step 2: Send the CreateStack request
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

  -- Step 3: Extract stack ID from response
  let stackName = getStackName args
      stackId = fromMaybe stackName resp.stackId
      regionText = Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))

  -- Step 3b: Fetch and emit StackDefinition
  mStack <- getStack ctx stackId
  case mStack of
    Just cfnStack -> emit (OdStackDefinition (convertStack cfnStack regionText) True)
    Nothing -> pure ()

  -- Step 4: Poll for completion, emitting events through renderer
  emit (OdPollingStarted "Loading live events...")
  let pollCfg = defaultPollConfig
        { pcOnNewEvents = \newEvents -> do
            let converted = map (convertEventWithDuration (cfnStartTime ctx)) newEvents
            emit (OdNewStackEvents converted)
        , pcOnOperationComplete = \info -> emit (OdOperationComplete info)
        }
  pollResult <- pollForCompletion ctx stackId createTerminalStatuses pollCfg

  -- Step 5: Handle DELETE_COMPLETE (rollback caused stack deletion)
  case pollResult of
    PollSuccess "DELETE_COMPLETE" -> pure (Right 1)
    PollSuccess finalStatus -> do
      -- Step 6: Collect and emit stack contents
      contents <- collectStackContents ctx stackName
      emit (OdStackContents contents)

      -- Step 7: Return exit code based on success/failure
      if finalStatus `elem` createSuccessStates
        then pure (Right 0)
        else pure (Right 1)
    _ -> pure (Right 1)  -- timeout = failure
