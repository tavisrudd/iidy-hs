module Iidy.Cfn.Types
  ( CfnOperation(..)
  , cfnOperationStr
  , isReadOnlyOperation
  , StackChangeType(..)
  , StackArgs(..)
  , emptyStackArgs
  , getStackName
  ) where

import Data.Aeson (Value)
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)

data CfnOperation
  = OpCreateStack
  | OpUpdateStack
  | OpDeleteStack
  | OpDescribeStack
  | OpCreateOrUpdate
  | OpCreateChangeset
  | OpExecuteChangeset
  | OpEstimateCost
  | OpListStacks
  | OpWatchStack
  | OpGetStackTemplate
  | OpDescribeStackDrift
  | OpTemplateApprovalRequest
  | OpTemplateApprovalReview
  | OpConvertStackToIidy
  | OpLintTemplate
  deriving stock (Show, Eq, Ord)

cfnOperationStr :: CfnOperation -> Text
cfnOperationStr = \case
  OpCreateStack             -> "create-stack"
  OpUpdateStack             -> "update-stack"
  OpDeleteStack             -> "delete-stack"
  OpDescribeStack           -> "describe-stack"
  OpCreateOrUpdate          -> "create-or-update"
  OpCreateChangeset         -> "create-changeset"
  OpExecuteChangeset        -> "execute-changeset"
  OpEstimateCost            -> "estimate-cost"
  OpListStacks              -> "list-stacks"
  OpWatchStack              -> "watch-stack"
  OpGetStackTemplate        -> "get-stack-template"
  OpDescribeStackDrift      -> "describe-stack-drift"
  OpTemplateApprovalRequest -> "template-approval-request"
  OpTemplateApprovalReview  -> "template-approval-review"
  OpConvertStackToIidy      -> "convert-stack-to-iidy"
  OpLintTemplate            -> "lint-template"

isReadOnlyOperation :: CfnOperation -> Bool
isReadOnlyOperation = \case
  OpDescribeStack      -> True
  OpEstimateCost       -> True
  OpListStacks         -> True
  OpGetStackTemplate   -> True
  OpDescribeStackDrift -> True
  OpConvertStackToIidy -> True
  OpLintTemplate       -> True
  _                    -> False

data StackChangeType
  = ChangeCreate
  | ChangeUpdateWithChanges !Text  -- ^ stack_id
  | ChangeUpdateNoChanges
  deriving stock (Show, Eq)

-- | Parsed stack-args.yaml configuration
data StackArgs = StackArgs
  { saStackName                   :: !(Maybe Text)
  , saTemplate                    :: !(Maybe Text)
  , saApprovedTemplateLocation    :: !(Maybe Text)
  , saRegion                      :: !(Maybe Text)
  , saProfile                     :: !(Maybe Text)
  , saCapabilities                :: !(Maybe [Text])
  , saTags                        :: !(Maybe (Map Text Text))
  , saParameters                  :: !(Maybe (Map Text Text))
  , saNotificationArns            :: !(Maybe [Text])
  , saAssumeRoleArn               :: !(Maybe Text)
  , saServiceRoleArn              :: !(Maybe Text)
  , saRoleArn                     :: !(Maybe Text)
  , saTimeoutInMinutes            :: !(Maybe Int)
  , saOnFailure                   :: !(Maybe Text)
  , saDisableRollback             :: !(Maybe Bool)
  , saEnableTerminationProtection :: !(Maybe Bool)
  , saStackPolicy                 :: !(Maybe Value)
  , saResourceTypes               :: !(Maybe [Text])
  , saUsePreviousTemplate         :: !(Maybe Bool)
  , saUsePreviousParameterValues  :: !(Maybe [Text])
  , saCommandsBefore              :: !(Maybe [Text])
  } deriving stock (Show, Eq)

-- | Extract the stack name from StackArgs, falling back to "unnamed-stack".
getStackName :: StackArgs -> Text
getStackName args = fromMaybe "unnamed-stack" (saStackName args)

emptyStackArgs :: StackArgs
emptyStackArgs = StackArgs
  { saStackName                   = Nothing
  , saTemplate                    = Nothing
  , saApprovedTemplateLocation    = Nothing
  , saRegion                      = Nothing
  , saProfile                     = Nothing
  , saCapabilities                = Nothing
  , saTags                        = Nothing
  , saParameters                  = Nothing
  , saNotificationArns            = Nothing
  , saAssumeRoleArn               = Nothing
  , saServiceRoleArn              = Nothing
  , saRoleArn                     = Nothing
  , saTimeoutInMinutes            = Nothing
  , saOnFailure                   = Nothing
  , saDisableRollback             = Nothing
  , saEnableTerminationProtection = Nothing
  , saStackPolicy                 = Nothing
  , saResourceTypes               = Nothing
  , saUsePreviousTemplate         = Nothing
  , saUsePreviousParameterValues  = Nothing
  , saCommandsBefore              = Nothing
  }
