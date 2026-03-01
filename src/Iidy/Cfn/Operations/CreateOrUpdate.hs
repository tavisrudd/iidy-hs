-- | Create-or-update CloudFormation operation.
--
-- Checks whether a stack exists and dispatches to either createStack
-- or updateStack accordingly. When --changeset is specified, uses
-- changeset-based paths for both create and update.
--
-- Rust has 5 distinct paths:
--   1. Stack exists + no changeset + changes → direct update
--   2. Stack exists + no changeset + no changes → exit 0
--   3. Stack exists + changeset → UPDATE changeset → confirm → execute
--   4. Stack doesn't exist + no changeset → direct create
--   5. Stack doesn't exist + changeset → CREATE changeset → show def → confirm → execute
module Iidy.Cfn.Operations.CreateOrUpdate
  ( createOrUpdate
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import qualified Amazonka

import Iidy.Aws.ClientReqToken (TokenInfo(..))
import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.Operations.Changeset
  ( createChangeset
  , executeChangeset
  , buildChangeSetCreationResult
  , generateDashedName
  , confirmChangesetExecution
  )
import Iidy.Cfn.Operations.CreateStack (createStack)
import Iidy.Cfn.Operations.DescribeStack (convertStack)
import Iidy.Cfn.Operations.UpdateStack (updateStack)
import Iidy.Cfn.StackOperations (stackExists, getStack)
import Iidy.Cfn.Types (StackArgs(..), getStackName)
import Iidy.Output.Types (OutputData(..), ChangeSetInfo(..))

------------------------------------------------------------------------
-- Create-or-update operation
------------------------------------------------------------------------

-- | Create or update a CloudFormation stack, depending on whether it exists.
--
-- When @useChangeset@ is False, dispatches to direct create or update.
-- When @useChangeset@ is True, uses changeset-based paths for both cases.
createOrUpdate
  :: CfnContext
  -> StackArgs
  -> Bool                   -- ^ useChangeset flag
  -> Bool                   -- ^ skip confirmation (--yes flag)
  -> Maybe FilePath         -- ^ argsfile path for template resolution
  -> Text                   -- ^ environment name
  -> (OutputData -> IO ())  -- ^ output emitter for progress display
  -> IO (Either Text Int)
createOrUpdate ctx args useChangeset yesFlag argsfilePath env emit = do
  let stackName = getStackName args

  exists <- stackExists ctx stackName

  case (exists, useChangeset) of
    -- Path 1 & 2: Stack exists, no changeset → direct update
    (True,  False) -> updateStack ctx args argsfilePath env emit

    -- Path 3: Stack exists + changeset → UPDATE changeset → confirm → execute
    (True,  True)  -> updateWithChangeset ctx args yesFlag argsfilePath env emit

    -- Path 4: Stack doesn't exist, no changeset → direct create
    (False, False) -> createStack ctx args argsfilePath env emit

    -- Path 5: Stack doesn't exist + changeset → CREATE changeset → confirm → execute
    (False, True)  -> createWithChangeset ctx args yesFlag argsfilePath env emit

------------------------------------------------------------------------
-- Changeset path: update existing stack
------------------------------------------------------------------------

-- | Update an existing stack via changeset.
-- Creates an UPDATE changeset, shows result, confirms, then executes.
updateWithChangeset
  :: CfnContext
  -> StackArgs
  -> Bool                   -- ^ skip confirmation (--yes flag)
  -> Maybe FilePath         -- ^ argsfile path
  -> Text                   -- ^ environment name
  -> (OutputData -> IO ())  -- ^ output emitter
  -> IO (Either Text Int)
updateWithChangeset ctx args yesFlag argsfilePath env emit = do
  let stackName = getStackName args
      regionText = Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))

  -- Fetch and emit StackDefinition
  mStack <- getStack ctx stackName
  case mStack of
    Just cfnStack -> emit (OdStackDefinition (convertStack cfnStack regionText) True)
    Nothing -> pure ()

  -- Generate deterministic changeset name from token
  let tokenPrefix = T.take 8 (tiValue (cfnPrimaryToken ctx))
      csName = "iidy-create-or-update-" <> tokenPrefix

  -- Create UPDATE changeset
  result <- createChangeset ctx args csName True argsfilePath env
  case result of
    Left err -> pure (Left err)
    Right info -> do
      let argsfileText = maybe "" T.pack argsfilePath
          csResult = buildChangeSetCreationResult info True argsfileText
      emit (OdChangeSetResult csResult)

      -- Check if changeset failed (e.g. invalid parameters)
      if csiStatus info == "FAILED"
        then pure (Left (fromMaybe "Changeset creation failed" (csiStatusReason info)))
        else do
          -- Confirm execution
          confirmed <- confirmChangesetExecution yesFlag
          if not confirmed
            then pure (Right 130)
            else executeChangeset ctx stackName csName emit

------------------------------------------------------------------------
-- Changeset path: create new stack
------------------------------------------------------------------------

-- | Create a new stack via changeset.
-- Creates a CREATE changeset, fetches the new stack definition (now in
-- REVIEW_IN_PROGRESS), shows changeset result, confirms, then executes.
createWithChangeset
  :: CfnContext
  -> StackArgs
  -> Bool                   -- ^ skip confirmation (--yes flag)
  -> Maybe FilePath         -- ^ argsfile path
  -> Text                   -- ^ environment name
  -> (OutputData -> IO ())  -- ^ output emitter
  -> IO (Either Text Int)
createWithChangeset ctx args yesFlag argsfilePath env emit = do
  let stackName = getStackName args
      regionText = Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))

  -- Generate random changeset name (docker-style)
  csName <- generateDashedName

  -- Create CREATE changeset (stack doesn't exist yet)
  result <- createChangeset ctx args csName False argsfilePath env
  case result of
    Left err -> pure (Left err)
    Right info -> do
      -- Stack now exists in REVIEW_IN_PROGRESS — fetch and show definition
      mStack <- getStack ctx stackName
      case mStack of
        Just cfnStack -> emit (OdStackDefinition (convertStack cfnStack regionText) True)
        Nothing -> pure ()

      -- Show changeset result
      let argsfileText = maybe "" T.pack argsfilePath
          csResult = buildChangeSetCreationResult info False argsfileText
      emit (OdChangeSetResult csResult)

      -- Check if changeset failed (e.g. invalid parameters)
      if csiStatus info == "FAILED"
        then pure (Left (fromMaybe "Changeset creation failed" (csiStatusReason info)))
        else do
          -- Confirm execution
          confirmed <- confirmChangesetExecution yesFlag
          if not confirmed
            then pure (Right 130)
            else executeChangeset ctx stackName csName emit
