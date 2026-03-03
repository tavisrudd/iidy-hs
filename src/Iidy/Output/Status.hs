module Iidy.Output.Status
  ( StatusCategory(..)
  , categorizeStatus
  , isStatusInProgress
  , isStatusComplete
  , isStatusFailed
  , isStatusTerminal
  ) where

import Iidy.Cfn.Status (StackStatus(..), isFailed, isInProgress, isSuccess)

-- | Categorization of CloudFormation resource statuses
data StatusCategory
  = StatusInProgress
  | StatusComplete
  | StatusFailed
  | StatusSkipped
  | StatusUnknown
  deriving stock (Show, Eq, Ord)

-- | Categorize a StackStatus into a display category
categorizeStatus :: StackStatus -> StatusCategory
categorizeStatus = \case
  DeleteSkipped -> StatusSkipped
  s | isInProgress s -> StatusInProgress
    | isSuccess s    -> StatusComplete
    | isFailed s     -> StatusFailed
    | otherwise      -> StatusUnknown

isStatusInProgress :: StackStatus -> Bool
isStatusInProgress s = categorizeStatus s == StatusInProgress

isStatusComplete :: StackStatus -> Bool
isStatusComplete s = categorizeStatus s == StatusComplete

isStatusFailed :: StackStatus -> Bool
isStatusFailed s = categorizeStatus s == StatusFailed

isStatusTerminal :: StackStatus -> Bool
isStatusTerminal s = case categorizeStatus s of
  StatusComplete -> True
  StatusFailed   -> True
  _              -> False
