-- | CloudFormation stack/resource status ADT.
--
-- Replaces stringly-typed status predicates with a proper sum type
-- that covers all AWS CloudFormation stack and resource statuses.
module Iidy.Cfn.Status
  ( StackStatus(..)
    -- * Conversion
  , toText
  , fromText
  , fromCfnStackStatus
  , fromCfnResourceStatus
    -- * Predicates
  , isTerminal
  , isSuccess
  , isFailed
  , isInProgress
  , isRollback
    -- * Status sets
  , allTerminalStatuses
  , terminalResourceStatuses
    -- * Re-exports for compatibility
  , isTerminalResourceStatus
  , isTerminalStackStatus
  , isFailureStatus
  , isSuccessStatus
  , isInProgressStatus
  , isRollbackStatus
  ) where

import Data.Text (Text)
import qualified Data.Map.Strict as Map

import qualified Amazonka.CloudFormation.Types as CF

------------------------------------------------------------------------
-- ADT
------------------------------------------------------------------------

data StackStatus
  = CreateInProgress
  | CreateComplete
  | CreateFailed
  | DeleteInProgress
  | DeleteComplete
  | DeleteFailed
  | UpdateInProgress
  | UpdateComplete
  | UpdateFailed
  | UpdateRollbackInProgress
  | UpdateRollbackComplete
  | UpdateRollbackFailed
  | RollbackInProgress
  | RollbackComplete
  | RollbackFailed
  | ImportInProgress
  | ImportComplete
  | ImportRollbackInProgress
  | ImportRollbackComplete
  | ImportRollbackFailed
  | ReviewInProgress
  | DeleteSkipped
  deriving (Eq, Ord, Show, Bounded, Enum)

------------------------------------------------------------------------
-- Conversion: ADT <-> Text
------------------------------------------------------------------------

-- | Convert a StackStatus to its AWS-style text representation.
toText :: StackStatus -> Text
toText = \case
  CreateInProgress         -> "CREATE_IN_PROGRESS"
  CreateComplete           -> "CREATE_COMPLETE"
  CreateFailed             -> "CREATE_FAILED"
  DeleteInProgress         -> "DELETE_IN_PROGRESS"
  DeleteComplete           -> "DELETE_COMPLETE"
  DeleteFailed             -> "DELETE_FAILED"
  UpdateInProgress         -> "UPDATE_IN_PROGRESS"
  UpdateComplete           -> "UPDATE_COMPLETE"
  UpdateFailed             -> "UPDATE_FAILED"
  UpdateRollbackInProgress -> "UPDATE_ROLLBACK_IN_PROGRESS"
  UpdateRollbackComplete   -> "UPDATE_ROLLBACK_COMPLETE"
  UpdateRollbackFailed     -> "UPDATE_ROLLBACK_FAILED"
  RollbackInProgress       -> "ROLLBACK_IN_PROGRESS"
  RollbackComplete         -> "ROLLBACK_COMPLETE"
  RollbackFailed           -> "ROLLBACK_FAILED"
  ImportInProgress         -> "IMPORT_IN_PROGRESS"
  ImportComplete           -> "IMPORT_COMPLETE"
  ImportRollbackInProgress -> "IMPORT_ROLLBACK_IN_PROGRESS"
  ImportRollbackComplete   -> "IMPORT_ROLLBACK_COMPLETE"
  ImportRollbackFailed     -> "IMPORT_ROLLBACK_FAILED"
  ReviewInProgress         -> "REVIEW_IN_PROGRESS"
  DeleteSkipped            -> "DELETE_SKIPPED"

-- | Parse a StackStatus from its AWS-style text representation.
fromText :: Text -> Maybe StackStatus
fromText t = Map.lookup t textToStatusMap

-- | Lookup map for fromText (built once from all constructors).
textToStatusMap :: Map.Map Text StackStatus
textToStatusMap = Map.fromList [(toText s, s) | s <- [minBound .. maxBound]]

------------------------------------------------------------------------
-- Conversion: amazonka types -> StackStatus
------------------------------------------------------------------------

-- | Convert from amazonka's CF.StackStatus to our StackStatus.
fromCfnStackStatus :: CF.StackStatus -> StackStatus
fromCfnStackStatus = \case
  CF.StackStatus_CREATE_IN_PROGRESS          -> CreateInProgress
  CF.StackStatus_CREATE_COMPLETE             -> CreateComplete
  CF.StackStatus_CREATE_FAILED               -> CreateFailed
  CF.StackStatus_DELETE_IN_PROGRESS          -> DeleteInProgress
  CF.StackStatus_DELETE_COMPLETE             -> DeleteComplete
  CF.StackStatus_DELETE_FAILED               -> DeleteFailed
  CF.StackStatus_UPDATE_IN_PROGRESS          -> UpdateInProgress
  CF.StackStatus_UPDATE_COMPLETE             -> UpdateComplete
  CF.StackStatus_UPDATE_FAILED               -> UpdateFailed
  CF.StackStatus_UPDATE_ROLLBACK_IN_PROGRESS -> UpdateRollbackInProgress
  CF.StackStatus_UPDATE_ROLLBACK_COMPLETE    -> UpdateRollbackComplete
  CF.StackStatus_UPDATE_ROLLBACK_FAILED      -> UpdateRollbackFailed
  CF.StackStatus_ROLLBACK_IN_PROGRESS        -> RollbackInProgress
  CF.StackStatus_ROLLBACK_COMPLETE           -> RollbackComplete
  CF.StackStatus_ROLLBACK_FAILED             -> RollbackFailed
  CF.StackStatus_IMPORT_IN_PROGRESS          -> ImportInProgress
  CF.StackStatus_IMPORT_COMPLETE             -> ImportComplete
  CF.StackStatus_IMPORT_ROLLBACK_IN_PROGRESS -> ImportRollbackInProgress
  CF.StackStatus_IMPORT_ROLLBACK_COMPLETE    -> ImportRollbackComplete
  CF.StackStatus_IMPORT_ROLLBACK_FAILED      -> ImportRollbackFailed
  CF.StackStatus_REVIEW_IN_PROGRESS          -> ReviewInProgress
  -- Catch-all for any future amazonka constructors; fall back to the text representation
  other -> case fromText (CF.fromStackStatus other) of
    Just s  -> s
    Nothing -> CreateFailed  -- defensive fallback, should never happen

-- | Convert from amazonka's CF.ResourceStatus to our StackStatus.
-- Resource statuses are a subset of stack statuses.
fromCfnResourceStatus :: CF.ResourceStatus -> StackStatus
fromCfnResourceStatus = \case
  CF.ResourceStatus_CREATE_IN_PROGRESS          -> CreateInProgress
  CF.ResourceStatus_CREATE_COMPLETE             -> CreateComplete
  CF.ResourceStatus_CREATE_FAILED               -> CreateFailed
  CF.ResourceStatus_DELETE_IN_PROGRESS          -> DeleteInProgress
  CF.ResourceStatus_DELETE_COMPLETE             -> DeleteComplete
  CF.ResourceStatus_DELETE_FAILED               -> DeleteFailed
  CF.ResourceStatus_UPDATE_IN_PROGRESS          -> UpdateInProgress
  CF.ResourceStatus_UPDATE_COMPLETE             -> UpdateComplete
  CF.ResourceStatus_UPDATE_FAILED               -> UpdateFailed
  CF.ResourceStatus_ROLLBACK_IN_PROGRESS        -> RollbackInProgress
  CF.ResourceStatus_ROLLBACK_COMPLETE           -> RollbackComplete
  CF.ResourceStatus_ROLLBACK_FAILED             -> RollbackFailed
  CF.ResourceStatus_IMPORT_IN_PROGRESS          -> ImportInProgress
  CF.ResourceStatus_IMPORT_COMPLETE             -> ImportComplete
  CF.ResourceStatus_IMPORT_ROLLBACK_IN_PROGRESS -> ImportRollbackInProgress
  CF.ResourceStatus_IMPORT_ROLLBACK_COMPLETE    -> ImportRollbackComplete
  CF.ResourceStatus_IMPORT_ROLLBACK_FAILED      -> ImportRollbackFailed
  CF.ResourceStatus_DELETE_SKIPPED              -> DeleteSkipped
  CF.ResourceStatus_UPDATE_ROLLBACK_IN_PROGRESS -> UpdateRollbackInProgress
  CF.ResourceStatus_UPDATE_ROLLBACK_COMPLETE    -> UpdateRollbackComplete
  CF.ResourceStatus_UPDATE_ROLLBACK_FAILED      -> UpdateRollbackFailed
  -- Catch-all for any future amazonka constructors
  other -> case fromText (CF.fromResourceStatus other) of
    Just s  -> s
    Nothing -> CreateFailed  -- defensive fallback

------------------------------------------------------------------------
-- Predicates
------------------------------------------------------------------------

-- | Is this status terminal (no further state transitions expected)?
--
-- Notable: UPDATE_FAILED is NOT terminal — CFN auto-initiates rollback.
isTerminal :: StackStatus -> Bool
isTerminal = \case
  CreateComplete           -> True
  CreateFailed             -> True
  DeleteComplete           -> True
  DeleteFailed             -> True
  RollbackComplete         -> True
  RollbackFailed           -> True
  UpdateComplete           -> True
  UpdateRollbackComplete   -> True
  UpdateRollbackFailed     -> True
  ImportComplete           -> True
  ImportRollbackComplete   -> True
  ImportRollbackFailed     -> True
  DeleteSkipped            -> True
  ReviewInProgress         -> True
  _                        -> False

-- | Is this a success status?
isSuccess :: StackStatus -> Bool
isSuccess = \case
  CreateComplete         -> True
  UpdateComplete         -> True
  DeleteComplete         -> True
  ImportComplete         -> True
  _                      -> False

-- | Is this a failure status?
isFailed :: StackStatus -> Bool
isFailed = \case
  CreateFailed           -> True
  DeleteFailed           -> True
  UpdateFailed           -> True
  UpdateRollbackFailed   -> True
  RollbackFailed         -> True
  ImportRollbackFailed   -> True
  _                      -> False

-- | Is this an in-progress status?
isInProgress :: StackStatus -> Bool
isInProgress = \case
  CreateInProgress         -> True
  DeleteInProgress         -> True
  UpdateInProgress         -> True
  UpdateRollbackInProgress -> True
  RollbackInProgress       -> True
  ImportInProgress         -> True
  ImportRollbackInProgress -> True
  ReviewInProgress         -> True
  _                        -> False

-- | Is this a rollback-related status?
isRollback :: StackStatus -> Bool
isRollback = \case
  RollbackInProgress       -> True
  RollbackComplete         -> True
  RollbackFailed           -> True
  UpdateRollbackInProgress -> True
  UpdateRollbackComplete   -> True
  UpdateRollbackFailed     -> True
  ImportRollbackInProgress -> True
  ImportRollbackComplete   -> True
  ImportRollbackFailed     -> True
  _                        -> False

------------------------------------------------------------------------
-- Status sets
------------------------------------------------------------------------

-- | All terminal stack statuses.
allTerminalStatuses :: [StackStatus]
allTerminalStatuses = filter isTerminal [minBound .. maxBound]

-- | Terminal resource statuses (full terminal set minus ReviewInProgress,
-- which is a stack-level-only state).
terminalResourceStatuses :: [StackStatus]
terminalResourceStatuses = filter (/= ReviewInProgress) allTerminalStatuses

------------------------------------------------------------------------
-- Backward-compatible aliases (operate on StackStatus)
------------------------------------------------------------------------

-- | Check if a StackStatus is terminal for resource events.
isTerminalResourceStatus :: StackStatus -> Bool
isTerminalResourceStatus s = s `elem` terminalResourceStatuses

-- | Check if a StackStatus is terminal for stack events.
isTerminalStackStatus :: StackStatus -> Bool
isTerminalStackStatus = isTerminal

-- | Check if a StackStatus is a failure.
isFailureStatus :: StackStatus -> Bool
isFailureStatus = isFailed

-- | Check if a StackStatus is a success.
isSuccessStatus :: StackStatus -> Bool
isSuccessStatus = isSuccess

-- | Check if a StackStatus is in progress.
isInProgressStatus :: StackStatus -> Bool
isInProgressStatus = isInProgress

-- | Check if a StackStatus is rollback-related.
isRollbackStatus :: StackStatus -> Bool
isRollbackStatus = isRollback
