module Iidy.Output.Status
  ( StatusCategory(..)
  , categorizeStatus
  , isStatusInProgress
  , isStatusComplete
  , isStatusFailed
  , isStatusTerminal
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Categorization of CloudFormation resource statuses
data StatusCategory
  = StatusInProgress
  | StatusComplete
  | StatusFailed
  | StatusSkipped
  | StatusUnknown
  deriving stock (Show, Eq, Ord)

-- | Categorize a CloudFormation status string
categorizeStatus :: Text -> StatusCategory
categorizeStatus status
  | T.isSuffixOf "_IN_PROGRESS" status = StatusInProgress
  | status == "REVIEW_IN_PROGRESS"     = StatusInProgress
  | T.isSuffixOf "_COMPLETE" status    = StatusComplete
  | T.isSuffixOf "_FAILED" status      = StatusFailed
  | status == "DELETE_SKIPPED"         = StatusSkipped
  | otherwise                          = StatusUnknown

isStatusInProgress :: Text -> Bool
isStatusInProgress s = categorizeStatus s == StatusInProgress

isStatusComplete :: Text -> Bool
isStatusComplete s = categorizeStatus s == StatusComplete

isStatusFailed :: Text -> Bool
isStatusFailed s = categorizeStatus s == StatusFailed

isStatusTerminal :: Text -> Bool
isStatusTerminal s = case categorizeStatus s of
  StatusComplete -> True
  StatusFailed   -> True
  _              -> False
