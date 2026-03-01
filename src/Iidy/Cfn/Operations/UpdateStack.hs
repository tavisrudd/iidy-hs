-- | UpdateStack CloudFormation operation.
--
-- Builds and sends an UpdateStack request, handles the "No updates are to be
-- performed" ValidationError as a success case, polls for completion, collects
-- stack contents, and returns an exit code.
--
-- Supports two paths:
--   * Direct update (default)
--   * Changeset-based update (--changeset flag): creates a changeset,
--     shows it to the user, prompts for confirmation, then executes.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.UpdateStack
  ( updateStack
  , updateStackWithChangeset
  -- * Internal (exported for testing)
  , isNoUpdatesError
  ) where

import Control.Exception (try, throwIO)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Control.Monad.Trans.Resource (runResourceT)

import qualified Amazonka
import qualified Amazonka.CloudFormation.UpdateStack as US

import Iidy.Aws.ClientReqToken (TokenInfo(..))
import Iidy.Cfn.Context (CfnContext(..), updateSuccessStates)
import Iidy.Cfn.Operations.Changeset
  ( createChangeset
  , executeChangeset
  , buildChangeSetCreationResult
  , confirmChangesetExecution
  )
import Iidy.Cfn.Operations.DescribeStack (convertEventWithDuration, convertStack)
import Iidy.Cfn.RequestBuilder (buildUpdateStackRequest)
import Iidy.Cfn.StackOperations
  ( collectStackContents
  , getStack
  , defaultPollConfig
  , PollConfig(..)
  , getStackId
  , pollForCompletion
  )
import Iidy.Cfn.Types (StackArgs(..), getStackName)
import Iidy.Output.Types (OutputData(..), ChangeSetInfo(..))

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
-- Update stack operation (direct path)
------------------------------------------------------------------------

-- | Run the update-stack CloudFormation operation (direct path).
--
-- Steps:
--   1. Build the UpdateStack request via RequestBuilder.
--   2. Send the request to CloudFormation, catching errors.
--   3. On "No updates" ValidationError, emit StackDefinition then re-throw
--      so the error is displayed by the top-level handler (matching Rust).
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
  let stackName = getStackName args

  -- Step 1: Build the UpdateStack request (use primary token)
  (req, _token) <- buildUpdateStackRequest ctx args True argsfilePath env

  -- Step 2 & 3: Send the request, catching the "No updates" case
  sendResult <- try (runResourceT $ Amazonka.send (cfnEnv ctx) req)
    :: IO (Either Amazonka.Error US.UpdateStackResponse)

  case sendResult of
    Left awsErr
      | isNoUpdatesError awsErr -> do
          -- Show Stack Details before re-throwing, matching Rust behavior
          let regionText = Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))
          mStack <- getStack ctx stackName
          case mStack of
            Just cfnStack -> emit (OdStackDefinition (convertStack cfnStack regionText) True)
            Nothing -> pure ()
          -- Re-throw so the error handler displays the ValidationError
          throwIO awsErr
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
      emit (OdPollingStarted "Loading live events...")
      let pollCfg = defaultPollConfig
            { pcOnNewEvents = \newEvents -> do
                let converted = map (convertEventWithDuration (cfnStartTime ctx)) newEvents
                emit (OdNewStackEvents converted)
            , pcOnOperationComplete = \info -> emit (OdOperationComplete info)
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
-- Update stack via changeset (--changeset path)
------------------------------------------------------------------------

-- | Update a stack via changeset: create changeset, show result,
-- confirm execution, then execute.
--
-- Steps:
--   1. Fetch and emit StackDefinition.
--   2. Generate changeset name from token (deterministic).
--   3. Create an UPDATE changeset.
--   4. Emit ChangeSetResult.
--   5. Prompt for confirmation (unless --yes).
--   6. Execute the changeset and watch for completion.
updateStackWithChangeset
  :: CfnContext
  -> StackArgs
  -> Bool                   -- ^ skip confirmation (--yes flag)
  -> Maybe FilePath         -- ^ argsfile path for template resolution
  -> Text                   -- ^ environment name
  -> (OutputData -> IO ())  -- ^ output emitter for progress display
  -> IO (Either Text Int)
updateStackWithChangeset ctx args yesFlag argsfilePath env emit = do
  let stackName = getStackName args
      regionText = Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))

  -- Step 1: Fetch and emit StackDefinition
  mStack <- getStack ctx stackName
  case mStack of
    Just cfnStack -> emit (OdStackDefinition (convertStack cfnStack regionText) True)
    Nothing -> pure ()

  -- Step 2: Generate deterministic changeset name from token
  let tokenPrefix = T.take 8 (tiValue (cfnPrimaryToken ctx))
      csName = "iidy-update-" <> tokenPrefix

  -- Step 3: Create the UPDATE changeset
  result <- createChangeset ctx args csName True argsfilePath env
  case result of
    Left err -> pure (Left err)
    Right info -> do
      -- Step 4: Emit ChangeSetResult
      let argsfileText = maybe "" T.pack argsfilePath
          csResult = buildChangeSetCreationResult info True argsfileText
      emit (OdChangeSetResult csResult)

      -- Step 5: Check if changeset failed (e.g. invalid parameters)
      if csiStatus info == "FAILED"
        then pure (Left (fromMaybe "Changeset creation failed" (csiStatusReason info)))
        else do
          -- Step 6: Confirm execution
          confirmed <- confirmChangesetExecution yesFlag
          if not confirmed
            then pure (Right 130)  -- user cancelled
            else do
              -- Step 7: Execute changeset and watch
              executeChangeset ctx stackName csName emit

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
