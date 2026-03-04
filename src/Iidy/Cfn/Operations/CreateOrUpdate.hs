{- | Create-or-update CloudFormation operation.

Checks whether a stack exists and dispatches to either createStack
or updateStack accordingly. When --changeset is specified, uses
changeset-based paths for both create and update.

Rust has 5 distinct paths:
  1. Stack exists + no changeset + changes → direct update
  2. Stack exists + no changeset + no changes → exit 0
  3. Stack exists + changeset → UPDATE changeset → confirm → execute
  4. Stack doesn't exist + no changeset → direct create
  5. Stack doesn't exist + changeset → CREATE changeset → show def → confirm → execute
-}
module Iidy.Cfn.Operations.CreateOrUpdate (
    createOrUpdate,
) where

import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Iidy.Aws.ClientReqToken (TokenInfo (..))
import Iidy.Cfn.Context (CfnContext (..))
import Iidy.Cfn.Env (CfnM, askContext, askEmit, emitOutput)
import Iidy.Cfn.Operations.Changeset (
    buildChangeSetCreationResult,
    confirmChangesetExecution,
    createChangeset,
    executeChangeset,
    generateDashedName,
 )
import Iidy.Cfn.Operations.CreateStack (createStack)
import Iidy.Cfn.Operations.DescribeStack (emitStackDefinition)
import Iidy.Cfn.Operations.UpdateStack (updateStack)
import Iidy.Cfn.StackOperations (stackExists)
import Iidy.Cfn.Types (StackArgs (..))
import Iidy.Confirm (ConfirmResult (..))
import Iidy.Output.Types (ChangeSetInfo (..), OutputData (..))

------------------------------------------------------------------------
-- Create-or-update operation
------------------------------------------------------------------------

{- | Create or update a CloudFormation stack, depending on whether it exists.

When @useChangeset@ is False, dispatches to direct create or update.
When @useChangeset@ is True, uses changeset-based paths for both cases.
-}
createOrUpdate ::
    StackArgs ->
    -- | useChangeset flag
    Bool ->
    -- | skip confirmation (--yes flag)
    Bool ->
    -- | argsfile path for template resolution
    Maybe FilePath ->
    CfnM (Either Text Int)
createOrUpdate args useChangeset yesFlag argsfilePath = do
    ctx <- askContext
    let stackName = saStackName args

    exists <- liftIO $ stackExists ctx stackName

    case (exists, useChangeset) of
        -- Path 1 & 2: Stack exists, no changeset → direct update
        (True, False) -> updateStack args argsfilePath
        -- Path 3: Stack exists + changeset → UPDATE changeset → confirm → execute
        (True, True) -> updateWithChangeset args yesFlag argsfilePath
        -- Path 4: Stack doesn't exist, no changeset → direct create
        (False, False) -> createStack args argsfilePath
        -- Path 5: Stack doesn't exist + changeset → CREATE changeset → confirm → execute
        (False, True) -> createWithChangeset args yesFlag argsfilePath

------------------------------------------------------------------------
-- Changeset path: update existing stack
------------------------------------------------------------------------

{- | Update an existing stack via changeset.
Creates an UPDATE changeset, shows result, confirms, then executes.
-}
updateWithChangeset ::
    StackArgs ->
    -- | skip confirmation (--yes flag)
    Bool ->
    -- | argsfile path
    Maybe FilePath ->
    CfnM (Either Text Int)
updateWithChangeset args yesFlag argsfilePath = do
    ctx <- askContext
    emitFn <- askEmit
    let stackName = saStackName args

    -- Fetch and emit StackDefinition
    liftIO $ emitStackDefinition ctx stackName emitFn

    -- Generate deterministic changeset name from token
    let tokenPrefix = T.take 8 (tiValue (cfnPrimaryToken ctx))
        csName = "iidy-create-or-update-" <> tokenPrefix

    -- Create UPDATE changeset
    csResult' <- createChangeset args csName True argsfilePath
    case csResult' of
        Left err -> pure (Left err)
        Right info -> do
            let argsfileText = maybe "" T.pack argsfilePath
                csResult = buildChangeSetCreationResult info True argsfileText
            emitOutput (OdChangeSetResult csResult)

            -- Check if changeset failed (e.g. invalid parameters)
            if csiStatus info == "FAILED"
                then pure (Left (fromMaybe "Changeset creation failed" (csiStatusReason info)))
                else do
                    -- Confirm execution
                    result <- liftIO $ confirmChangesetExecution yesFlag
                    if result == Declined
                        then pure (Right 130)
                        else liftIO $ executeChangeset ctx stackName csName emitFn

------------------------------------------------------------------------
-- Changeset path: create new stack
------------------------------------------------------------------------

{- | Create a new stack via changeset.
Creates a CREATE changeset, fetches the new stack definition (now in
REVIEW_IN_PROGRESS), shows changeset result, confirms, then executes.
-}
createWithChangeset ::
    StackArgs ->
    -- | skip confirmation (--yes flag)
    Bool ->
    -- | argsfile path
    Maybe FilePath ->
    CfnM (Either Text Int)
createWithChangeset args yesFlag argsfilePath = do
    ctx <- askContext
    emitFn <- askEmit
    let stackName = saStackName args

    -- Generate random changeset name (docker-style)
    csName <- liftIO generateDashedName

    -- Create CREATE changeset (stack doesn't exist yet)
    csResult' <- createChangeset args csName False argsfilePath
    case csResult' of
        Left err -> pure (Left err)
        Right info -> do
            -- Stack now exists in REVIEW_IN_PROGRESS — fetch and show definition
            liftIO $ emitStackDefinition ctx stackName emitFn

            -- Show changeset result
            let argsfileText = maybe "" T.pack argsfilePath
                csResult = buildChangeSetCreationResult info False argsfileText
            emitOutput (OdChangeSetResult csResult)

            -- Check if changeset failed (e.g. invalid parameters)
            if csiStatus info == "FAILED"
                then pure (Left (fromMaybe "Changeset creation failed" (csiStatusReason info)))
                else do
                    -- Confirm execution
                    result <- liftIO $ confirmChangesetExecution yesFlag
                    if result == Declined
                        then pure (Right 130)
                        else liftIO $ executeChangeset ctx stackName csName emitFn
