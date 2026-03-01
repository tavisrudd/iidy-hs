module Iidy.Cfn.Status
  ( isTerminalResourceStatus
  , isTerminalStackStatus
  , isFailureStatus
  , isSuccessStatus
  , isInProgressStatus
  , isRollbackStatus
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Iidy.Cfn.Context (allTerminalStatuses)

-- | Terminal resource statuses — the full terminal set minus REVIEW_IN_PROGRESS,
-- which is a stack-level-only state (changeset-created stacks awaiting execution).
terminalResourceStatuses :: [Text]
terminalResourceStatuses = filter (/= "REVIEW_IN_PROGRESS") allTerminalStatuses

-- | Terminal stack statuses — the full terminal status set from Context.
terminalStackStatuses :: [Text]
terminalStackStatuses = allTerminalStatuses

isTerminalResourceStatus :: Text -> Bool
isTerminalResourceStatus s = s `elem` terminalResourceStatuses

isTerminalStackStatus :: Text -> Bool
isTerminalStackStatus s = s `elem` terminalStackStatuses

isFailureStatus :: Text -> Bool
isFailureStatus s = T.isSuffixOf "_FAILED" s

isSuccessStatus :: Text -> Bool
isSuccessStatus s = T.isSuffixOf "_COMPLETE" s && not (isRollbackStatus s)

isInProgressStatus :: Text -> Bool
isInProgressStatus s = T.isSuffixOf "_IN_PROGRESS" s

isRollbackStatus :: Text -> Bool
isRollbackStatus s = T.isInfixOf "ROLLBACK" s
