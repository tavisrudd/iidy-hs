{-# LANGUAGE OverloadedRecordDot #-}

{- | UpdateStack CloudFormation operation.

Builds and sends an UpdateStack request, handles the "No updates are to be
performed" ValidationError as a success case, polls for completion, collects
stack contents, and returns an exit code.

Supports two paths:
  * Direct update (default)
  * Changeset-based update (--changeset flag): creates a changeset,
    shows it to the user, prompts for confirmation, then executes.
-}
module Iidy.Cfn.Operations.UpdateStack (
    updateStack,
    updateStackWithChangeset,

    -- * Internal (exported for testing)
    isNoUpdatesError,
) where

import Control.Exception (throwIO, try)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Control.Monad.Trans.Resource (runResourceT)

import Amazonka qualified
import Amazonka.CloudFormation.UpdateStack qualified as US

import Iidy.Aws.ClientReqToken (TokenInfo (..))
import Iidy.Cfn.Context (CfnContext (..), updateSuccessStates, updateTerminalStatuses)
import Iidy.Cfn.Operations.Changeset (
    buildChangeSetCreationResult,
    confirmChangesetExecution,
    createChangeset,
    executeChangeset,
 )
import Iidy.Cfn.Operations.DescribeStack (emitStackDefinition, mkStandardPollConfig)
import Iidy.Cfn.RequestBuilder (buildUpdateStackRequest)
import Iidy.Cfn.StackOperations (
    PollResult (..),
    collectStackContents,
    getStackId,
    pollForCompletion,
 )
import Iidy.Cfn.Status (StackStatus (..))
import Iidy.Cfn.Types (StackArgs (..))
import Iidy.Confirm (ConfirmResult (..))
import Iidy.Output.Types (ChangeSetInfo (..), OutputData (..))

-- | The CloudFormation error message returned when there are no changes to apply.
noUpdatesMessage :: Text
noUpdatesMessage = "No updates are to be performed"

------------------------------------------------------------------------
-- Update stack operation (direct path)
------------------------------------------------------------------------

{- | Run the update-stack CloudFormation operation (direct path).

Steps:
  1. Build the UpdateStack request via RequestBuilder.
  2. Send the request to CloudFormation, catching errors.
  3. On "No updates" ValidationError, emit StackDefinition then re-throw
     so the error is displayed by the top-level handler (matching Rust).
  4. Extract the stack ID from the response (or fall back to DescribeStacks).
  5. Poll until a terminal status is reached.
  6. Collect stack contents.
  7. Return 0 if the final status is in UPDATE_SUCCESS_STATES, 1 otherwise.
-}
updateStack ::
    CfnContext ->
    StackArgs ->
    -- | argsfile path for template resolution
    Maybe FilePath ->
    IO (Either Text Int)
updateStack ctx args argsfilePath = do
    let stackName = saStackName args
        emit = cfnEmit ctx

    -- Step 1: Build the UpdateStack request (use primary token)
    reqResult <- buildUpdateStackRequest ctx args True argsfilePath
    case reqResult of
        Left err -> pure (Left err)
        Right (req, _token) -> do
            -- Step 2 & 3: Send the request, catching the "No updates" case
            sendResult <-
                try (runResourceT $ Amazonka.send (cfnEnv ctx) req) ::
                    IO (Either Amazonka.Error US.UpdateStackResponse)

            case sendResult of
                Left awsErr
                    | isNoUpdatesError awsErr -> do
                        -- Show Stack Details before re-throwing, matching Rust behavior
                        emitStackDefinition ctx stackName emit
                        -- Re-throw so the error handler displays the ValidationError
                        throwIO awsErr
                    | otherwise ->
                        throwIO awsErr
                Right resp -> do
                    -- Step 4: Get stack ID (prefer the response, fall back to DescribeStacks)
                    mStackId <- case resp.stackId of
                        Just sid -> pure (Just sid)
                        Nothing -> getStackId ctx stackName

                    let stackId = fromMaybe stackName mStackId

                    -- Step 4b: Fetch and emit StackDefinition
                    emitStackDefinition ctx stackId emit

                    -- Step 5: Poll for completion, emitting events through renderer
                    emit (OdPollingStarted "Loading live events...")
                    let pollCfg = mkStandardPollConfig ctx emit
                    pollResult <- pollForCompletion ctx stackId updateTerminalStatuses pollCfg

                    -- Step 6: Return exit code based on success/failure
                    case pollResult of
                        PollSuccess DeleteComplete -> pure (Right 1)
                        PollSuccess finalStatus -> do
                            contents <- collectStackContents ctx stackName
                            emit (OdStackContents contents)
                            if finalStatus `elem` updateSuccessStates
                                then pure (Right 0)
                                else pure (Right 1)
                        _ -> pure (Right 1) -- timeout = failure; skip collectStackContents (stack may be transitioning)

------------------------------------------------------------------------
-- Update stack via changeset (--changeset path)
------------------------------------------------------------------------

{- | Update a stack via changeset: create changeset, show result,
confirm execution, then execute.

Steps:
  1. Fetch and emit StackDefinition.
  2. Generate changeset name from token (deterministic).
  3. Create an UPDATE changeset.
  4. Emit ChangeSetResult.
  5. Prompt for confirmation (unless --yes).
  6. Execute the changeset and watch for completion.
-}
updateStackWithChangeset ::
    CfnContext ->
    StackArgs ->
    -- | skip confirmation (--yes flag)
    Bool ->
    -- | argsfile path for template resolution
    Maybe FilePath ->
    IO (Either Text Int)
updateStackWithChangeset ctx args yesFlag argsfilePath = do
    let stackName = saStackName args
        emit = cfnEmit ctx

    -- Step 1: Fetch and emit StackDefinition
    emitStackDefinition ctx stackName emit

    -- Step 2: Generate deterministic changeset name from token
    let tokenPrefix = T.take 8 (tiValue (cfnPrimaryToken ctx))
        csName = "iidy-update-" <> tokenPrefix

    -- Step 3: Create the UPDATE changeset
    csResult' <- createChangeset ctx args csName True argsfilePath
    case csResult' of
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
                    result <- confirmChangesetExecution yesFlag
                    if result == Declined
                        then pure (Right 130) -- user cancelled
                        else do
                            -- Step 7: Execute changeset and watch
                            executeChangeset ctx stackName csName

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

{- | Check whether an Amazonka error is the "No updates are to be performed"
ValidationError that CloudFormation returns when there are no stack changes.
-}
isNoUpdatesError :: Amazonka.Error -> Bool
isNoUpdatesError (Amazonka.ServiceError se) =
    se.code == Amazonka.ErrorCode "ValidationError"
        && case se.message of
            Just msg -> noUpdatesMessage `T.isInfixOf` Amazonka.fromErrorMessage msg
            Nothing -> False
isNoUpdatesError _ = False
