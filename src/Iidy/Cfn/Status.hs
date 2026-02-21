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

terminalResourceStatuses :: [Text]
terminalResourceStatuses =
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
  ]

terminalStackStatuses :: [Text]
terminalStackStatuses = terminalResourceStatuses <> ["REVIEW_IN_PROGRESS"]

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
