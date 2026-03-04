{-# LANGUAGE OverloadedRecordDot #-}

{- | CreateStack CloudFormation operation.

Builds and sends a CreateStack request, polls for completion,
collects stack contents, and returns an exit code.
-}
module Iidy.Cfn.Operations.CreateStack (
    createStack,
) where

import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Control.Monad.Trans.Resource (runResourceT)

import Amazonka qualified
import Amazonka.CloudFormation.CreateStack qualified as CS

import Iidy.Cfn.Context (CfnContext (..), createSuccessStates, createTerminalStatuses)
import Iidy.Cfn.Env (CfnM, askContext, askEmit, emitOutput)
import Iidy.Cfn.Operations.DescribeStack (emitStackDefinition, mkStandardPollConfig)
import Iidy.Cfn.RequestBuilder (buildCreateStackRequest)
import Iidy.Cfn.StackOperations (
    PollResult (..),
    collectStackContents,
    pollForCompletion,
 )
import Iidy.Cfn.Status (StackStatus (..))
import Iidy.Cfn.Types (StackArgs (..))
import Iidy.Output.Types (OutputData (..))

------------------------------------------------------------------------
-- Create stack operation
------------------------------------------------------------------------

{- | Run the create-stack CloudFormation operation.

Steps:
  1. Build the CreateStack request via RequestBuilder.
  2. Send the request to CloudFormation.
  3. Extract the new stack ID from the response.
  4. Poll until a terminal status is reached, emitting events.
  5. On DELETE_COMPLETE, return exit code 1 (stack was rolled back and deleted).
  6. Collect stack contents for display.
  7. Return 0 if the final status is in CREATE_SUCCESS_STATES, 1 otherwise.
-}
createStack ::
    StackArgs ->
    -- | argsfile path for template resolution
    Maybe FilePath ->
    CfnM (Either Text Int)
createStack args argsfilePath = do
    -- Step 1: Build the request (use primary token for create)
    reqResult <- buildCreateStackRequest args True argsfilePath
    case reqResult of
        Left err -> pure (Left err)
        Right (req, _token) -> do
            ctx <- askContext
            emitFn <- askEmit

            -- Step 2: Send the CreateStack request
            resp <- liftIO $ runResourceT $ Amazonka.send (cfnEnv ctx) req

            -- Step 3: Extract stack ID from response
            let stackName = saStackName args
                stackId = fromMaybe stackName resp.stackId

            -- Step 3b: Fetch and emit StackDefinition
            liftIO $ emitStackDefinition ctx stackId emitFn

            -- Step 4: Poll for completion, emitting events through renderer
            emitOutput (OdPollingStarted "Loading live events...")
            let pollCfg = mkStandardPollConfig ctx emitFn
            pollResult <- liftIO $ pollForCompletion ctx stackId createTerminalStatuses pollCfg

            -- Step 5: Handle DELETE_COMPLETE (rollback caused stack deletion)
            case pollResult of
                PollSuccess DeleteComplete -> pure (Right 1)
                PollSuccess finalStatus -> do
                    -- Step 6: Collect and emit stack contents
                    contents <- liftIO $ collectStackContents ctx stackName
                    emitOutput (OdStackContents contents)

                    -- Step 7: Return exit code based on success/failure
                    if finalStatus `elem` createSuccessStates
                        then pure (Right 0)
                        else pure (Right 1)
                _ -> pure (Right 1) -- timeout = failure; skip collectStackContents (stack may be partial)
