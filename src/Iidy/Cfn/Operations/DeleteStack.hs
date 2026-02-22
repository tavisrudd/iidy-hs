-- | DeleteStack CloudFormation operation.
--
-- Checks for stack existence, builds and sends a DeleteStack request,
-- then polls for DELETE_COMPLETE or terminal failure.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.DeleteStack
  ( deleteStack
  ) where

import Data.Text (Text)

import Control.Monad.Trans.Resource (runResourceT)

import qualified Amazonka

import Iidy.Cfn.Context (CfnContext(..), deleteSuccessStates)
import Iidy.Cfn.RequestBuilder (buildDeleteStackRequest)
import Iidy.Cfn.StackOperations
  ( defaultPollConfig
  , getStackId
  , pollForCompletion
  , stackExists
  )

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
--   2. Obtain the stack ARN for reliable polling through deletion.
--   3. Build the DeleteStack request.
--   4. Send the request to CloudFormation.
--   5. Poll until a terminal status is reached, using the stack ID/ARN.
--   6. Return 0 if the final status is DELETE_COMPLETE, 1 otherwise.
--
-- The @skipConfirmation@ parameter is accepted for API compatibility;
-- confirmation prompting is the caller's responsibility.
deleteStack
  :: CfnContext
  -> Text     -- ^ stack name
  -> Bool     -- ^ skip confirmation (--yes flag); caller handles prompt
  -> IO (Either Text Int)
deleteStack ctx stackName _skipConfirmation = do
  -- Step 1: Check stack existence
  exists <- stackExists ctx stackName
  if not exists
    then pure (Right 0)
    else do
      -- Step 2: Obtain stack ID/ARN for reliable post-delete polling
      mStackId <- getStackId ctx stackName
      let pollTarget = maybe stackName id mStackId

      -- Step 3: Build the DeleteStack request
      (req, _token) <- buildDeleteStackRequest ctx stackName

      -- Step 4: Send the DeleteStack request
      _resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

      -- Step 5: Poll for completion using stack ID (survives name deregistration)
      finalStatus <- pollForCompletion ctx pollTarget allTerminalStatuses defaultPollConfig

      -- Step 6: Return exit code based on final status
      if finalStatus `elem` deleteSuccessStates
        then pure (Right 0)
        else pure (Right 1)
