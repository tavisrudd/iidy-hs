-- | DeleteStack CloudFormation operation.
--
-- Checks for stack existence, builds and sends a DeleteStack request,
-- then polls for DELETE_COMPLETE or terminal failure.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.DeleteStack
  ( deleteStack
  ) where

import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T
import System.IO (hFlush, hSetBuffering, stdin, stdout, BufferMode(..))

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
--   1b. Prompt for confirmation unless --yes flag is set.
--   2. Obtain the stack ARN for reliable polling through deletion.
--   3. Build the DeleteStack request.
--   4. Send the request to CloudFormation.
--   5. Poll until a terminal status is reached, using the stack ID/ARN.
--   6. Return 0 if the final status is DELETE_COMPLETE, 1 otherwise.
--
deleteStack
  :: CfnContext
  -> Text     -- ^ stack name
  -> Bool     -- ^ skip confirmation (--yes flag)
  -> IO (Either Text Int)
deleteStack ctx stackName skipConfirmation = do
  -- Step 1: Check stack existence
  exists <- stackExists ctx stackName
  if not exists
    then pure (Right 0)
    else do
      -- Step 1b: Prompt for confirmation unless --yes
      confirmed <- if skipConfirmation
        then pure True
        else requestConfirmation
               ("Are you sure you want to DELETE the stack " <> T.unpack stackName <> "?")
      if not confirmed
        then pure (Right 130)  -- Exit code 130 = user cancelled
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

------------------------------------------------------------------------
-- Confirmation prompt
------------------------------------------------------------------------

-- | Ask the user to confirm an action on the terminal.
-- Returns True if the user types "y" or "yes", False otherwise.
requestConfirmation :: String -> IO Bool
requestConfirmation prompt = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout NoBuffering
  putStr $ prompt <> " [y/N] "
  hFlush stdout
  answer <- getLine
  pure $ map toLower answer `elem` ["y", "yes"]
