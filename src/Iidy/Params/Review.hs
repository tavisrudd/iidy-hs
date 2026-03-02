-- | SSM Parameter review workflow.
--
-- Reviews a pending parameter change (stored as path.pending)
-- and prompts the user to approve or reject it.
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Iidy.Params.Review
  ( paramReview
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Lens.Micro ((^.))

import Iidy.Confirm (requestConfirmation)
import Iidy.Params.Client (fetchParam)
import qualified Amazonka
import qualified Amazonka.SSM.GetParameter as GP
import qualified Amazonka.SSM.PutParameter as PP
import qualified Amazonka.SSM.DeleteParameter as DP
import qualified Amazonka.SSM.Types.Parameter as SSMP
import qualified Amazonka.SSM.Types.ParameterType as SSMPT

------------------------------------------------------------------------
-- Review
------------------------------------------------------------------------

-- | Review a pending SSM parameter change and optionally approve it.
--
-- Workflow:
--   1. Fetch the pending parameter (path.pending)
--   2. Fetch the current parameter (path)
--   3. Display current vs pending values
--   4. Prompt for confirmation
--   5. On approval: write pending value to main path, delete pending
--   6. On rejection: leave pending in place, return exit 130
paramReview :: Amazonka.Env -> Text -> IO (Either Text Int)
paramReview awsEnv path = do
  let pendingPath = path <> ".pending"

  -- 1. Fetch pending parameter (full object to preserve type)
  pendingResult <- fetchParamFull awsEnv pendingPath True
  case pendingResult of
    Left _ -> pure (Left ("No pending parameter found at " <> pendingPath))
    Right pendingParam -> do
      let pendingValue = pendingParam ^. SSMP.parameter_value
          paramType    = pendingParam ^. SSMP.parameter_type

      -- 2. Fetch current parameter
      currentResult <- fetchParam awsEnv path True
      let currentValue = either (const "(not set)") id currentResult

      -- 3. Display values
      TIO.putStrLn ""
      TIO.putStrLn $ "Parameter: " <> path
      TIO.putStrLn $ "Current value: " <> currentValue
      TIO.putStrLn $ "Pending value: " <> pendingValue
      TIO.putStrLn ""

      -- 4. Prompt for confirmation
      confirmed <- requestConfirmation "Would you like to approve these changes?"
      if confirmed
        then do
          -- 5. Apply: write pending value (preserving type), delete pending
          applyResult <- applyPendingChange awsEnv path pendingValue pendingPath paramType
          case applyResult of
            Left err -> pure (Left err)
            Right () -> do
              TIO.putStrLn $ "Parameter " <> path <> " updated successfully."
              pure (Right 0)
        else do
          TIO.putStrLn "Change not approved."
          pure (Right 130)

------------------------------------------------------------------------
-- SSM helpers
------------------------------------------------------------------------

-- | Fetch the full SSM Parameter object (value + type + metadata).
fetchParamFull :: Amazonka.Env -> Text -> Bool -> IO (Either Text SSMP.Parameter)
fetchParamFull awsEnv name withDecryption = do
  let req = (GP.newGetParameter name) { GP.withDecryption = Just withDecryption }
  result <- try @SomeException $ runResourceT $ Amazonka.send awsEnv req
  case result of
    Left ex    -> pure (Left (T.pack (show ex)))
    Right resp -> pure (Right resp.parameter)

-- | Apply a pending change: write the value to the main path and delete the pending.
-- The paramType is taken from the pending parameter to preserve the original type.
applyPendingChange :: Amazonka.Env -> Text -> Text -> Text -> SSMPT.ParameterType -> IO (Either Text ())
applyPendingChange awsEnv path pendingValue pendingPath paramType = do
  -- Write pending value to main parameter, preserving the original parameter type
  let putReq = (PP.newPutParameter path pendingValue)
                { PP.overwrite = Just True
                , PP.type' = Just paramType
                }
  putResult <- try @SomeException $ runResourceT $ Amazonka.send awsEnv putReq
  case putResult of
    Left ex -> pure (Left ("Failed to update parameter: " <> T.pack (show ex)))
    Right _ -> do
      -- Delete pending parameter
      let delReq = DP.newDeleteParameter pendingPath
      delResult <- try @SomeException $ runResourceT $ Amazonka.send awsEnv delReq
      case delResult of
        Left ex -> pure (Left ("Parameter updated but failed to delete pending: " <> T.pack (show ex)))
        Right _ -> pure (Right ())
