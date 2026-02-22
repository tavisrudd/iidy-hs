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

import Iidy.Cfn.Context (CfnContext(..), createSuccessStates)
import Iidy.Cfn.RequestBuilder (buildCreateStackRequest)
import Iidy.Cfn.StackOperations
  ( collectStackContents
  , defaultPollConfig
  , pollForCompletion
  )
import Iidy.Cfn.Types (StackArgs(..))

------------------------------------------------------------------------
-- Terminal statuses for create-stack polling
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

------------------------------------------------------------------------
-- Create stack operation
------------------------------------------------------------------------

-- | Run the create-stack CloudFormation operation.
--
-- Steps:
--   1. Build the CreateStack request via RequestBuilder.
--   2. Send the request to CloudFormation.
--   3. Extract the new stack ID from the response.
--   4. Poll until a terminal status is reached.
--   5. On DELETE_COMPLETE, return exit code 1 (stack was rolled back and deleted).
--   6. Collect stack contents for display.
--   7. Return 0 if the final status is in CREATE_SUCCESS_STATES, 1 otherwise.
createStack
  :: CfnContext
  -> StackArgs
  -> Maybe FilePath  -- ^ argsfile path for template resolution
  -> Text            -- ^ environment name
  -> IO (Either Text Int)
createStack ctx args argsfilePath env = do
  -- Step 1: Build the request (use primary token for create)
  (req, _token) <- buildCreateStackRequest ctx args True argsfilePath env

  -- Step 2: Send the CreateStack request
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

  -- Step 3: Extract stack ID from response
  let stackId = fromMaybe stackName resp.stackId
      stackName = fromMaybe "unnamed-stack" (saStackName args)

  -- Step 4: Poll for completion using all terminal statuses
  finalStatus <- pollForCompletion ctx stackId allTerminalStatuses defaultPollConfig

  -- Step 5: Handle DELETE_COMPLETE (rollback caused stack deletion)
  if finalStatus == "DELETE_COMPLETE"
    then pure (Right 1)
    else do
      -- Step 6: Collect stack contents (ignore result, side-effect for callers)
      _contents <- collectStackContents ctx stackName

      -- Step 7: Return exit code based on success/failure
      if finalStatus `elem` createSuccessStates
        then pure (Right 0)
        else pure (Right 1)
