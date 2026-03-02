module Iidy.Output.Types
  ( -- * Main output type
    OutputData(..)
    -- * Metadata & tokens
  , CommandMetadata(..)
    -- * Stack events
  , StackEvent(..)
  , StackEventWithTiming(..)
  , TruncationInfo(..)
  , StackEventsDisplay(..)
    -- * Stack definition
  , StackDefinition(..)
    -- * Stack contents
  , StackResourceInfo(..)
  , StackOutputInfo(..)
  , StackExportInfo(..)
  , StackStatusInfo(..)
  , StackContents(..)
    -- * Changesets
  , ChangeSetInfo(..)
  , ChangeInfo(..)
  , ChangeDetail(..)
  , ChangeSetCreationResult(..)
    -- * Status & results
  , StatusUpdate(..)
  , StatusLevel(..)
  , CommandResult(..)
  , FinalCommandSummary(..)
  , CommandSummaryResult(..)
    -- * Stack listing
  , StackListColumn(..)
  , StackListDisplay(..)
  , StackListEntry(..)
    -- * Errors
  , ErrorDetails(..)
  , ErrorInfo(..)
    -- * Operation lifecycle
  , OperationCompleteInfo(..)
  , InactivityTimeoutInfo(..)
  , StackChangeDetails(..)
  , StackAbsentInfo(..)
    -- * Drift
  , StackDrift(..)
  , DriftedResource(..)
  , PropertyDifference(..)
    -- * Cost & templates
  , CostEstimateInfo(..)
  , CostEstimate(..)
  , StackTemplate(..)
    -- * Approval
  , ApprovalRequestResult(..)
  , TemplateValidation(..)
  , ApprovalStatus(..)
  , TemplateDiff(..)
  , ApprovalResult(..)
    -- * Confirmation
  , ConfirmationRequest(..)
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)
import Iidy.Aws.ClientReqToken (TokenInfo)
import Iidy.Cfn.Types (StackChangeType)

------------------------------------------------------------------------
-- Main output enum
------------------------------------------------------------------------

data OutputData
  = OdCommandMetadata !CommandMetadata
  | OdStackDefinition !StackDefinition !Bool        -- ^ show_times flag
  | OdStackEvents !StackEventsDisplay
  | OdStackContents !StackContents
  | OdStatusUpdate !StatusUpdate
  | OdCommandResult !CommandResult
  | OdFinalCommandSummary !FinalCommandSummary
  | OdStackList !StackListDisplay
  | OdChangeSetResult !ChangeSetCreationResult
  | OdStackDrift !StackDrift
  | OdError !ErrorInfo
  | OdTokenInfo !TokenInfo
  | OdNewStackEvents ![StackEventWithTiming]
  | OdOperationComplete !OperationCompleteInfo
  | OdInactivityTimeout !InactivityTimeoutInfo
  | OdConfirmationPrompt !ConfirmationRequest
  | OdStackChangeDetails !StackChangeDetails
  | OdStackAbsentInfo !StackAbsentInfo
  | OdCostEstimate !CostEstimate
  | OdStackTemplate !StackTemplate
  | OdApprovalRequestResult !ApprovalRequestResult
  | OdTemplateValidation !TemplateValidation
  | OdApprovalStatus !ApprovalStatus
  | OdTemplateDiff !TemplateDiff
  | OdApprovalResult !ApprovalResult
  | OdPollingStarted !Text                          -- ^ spinner message for polling
  | OdRawOutput !Text                              -- ^ raw text output for non-CFN commands
  deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Metadata
------------------------------------------------------------------------

data CommandMetadata = CommandMetadata
  { cmEnvironment       :: !Text
  , cmRegion            :: !Text
  , cmProfile           :: !(Maybe Text)
  , cmCliArguments      :: !(Map Text Text)
  , cmIamServiceRole    :: !(Maybe Text)
  , cmCurrentIamPrincipal :: !Text
  , cmCredentialSource  :: !Text
  , cmVersion           :: !Text
  , cmPrimaryToken      :: !TokenInfo
  , cmDerivedTokens     :: ![TokenInfo]
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Stack events
------------------------------------------------------------------------

data StackEvent = StackEvent
  { seEventId            :: !Text
  , seStackId            :: !Text
  , seStackName          :: !Text
  , seLogicalResourceId  :: !Text
  , sePhysicalResourceId :: !(Maybe Text)
  , seResourceType       :: !Text
  , seTimestamp          :: !(Maybe UTCTime)
  , seResourceStatus     :: !Text
  , seResourceStatusReason :: !(Maybe Text)
  , seResourceProperties :: !(Maybe Text)
  , seClientRequestToken :: !(Maybe Text)
  } deriving stock (Show, Eq)

data StackEventWithTiming = StackEventWithTiming
  { sewEvent           :: !StackEvent
  , sewDurationSeconds :: !(Maybe Int)
  } deriving stock (Show, Eq)

data TruncationInfo = TruncationInfo
  { truncShown :: !Int
  , truncTotal :: !Int
  } deriving stock (Show, Eq)

data StackEventsDisplay = StackEventsDisplay
  { sedTitle     :: !Text
  , sedEvents    :: ![StackEventWithTiming]
  , sedMaxEvents :: !(Maybe Int)
  , sedTruncated :: !(Maybe TruncationInfo)
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Stack definition
------------------------------------------------------------------------

data StackDefinition = StackDefinition
  { sdName                   :: !Text
  , sdStacksetName           :: !(Maybe Text)
  , sdDescription            :: !(Maybe Text)
  , sdStatus                 :: !Text
  , sdStatusReason           :: !(Maybe Text)
  , sdCapabilities           :: ![Text]
  , sdServiceRole            :: !(Maybe Text)
  , sdTags                   :: !(Map Text Text)
  , sdParameters             :: !(Map Text Text)
  , sdDisableRollback        :: !Bool
  , sdTerminationProtection  :: !Bool
  , sdCreationTime           :: !(Maybe UTCTime)
  , sdLastUpdatedTime        :: !(Maybe UTCTime)
  , sdTimeoutInMinutes       :: !(Maybe Int)
  , sdNotificationArns       :: ![Text]
  , sdStackPolicy            :: !(Maybe Text)
  , sdArn                    :: !Text
  , sdConsoleUrl             :: !Text
  , sdRegion                 :: !Text
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Stack contents
------------------------------------------------------------------------

data StackResourceInfo = StackResourceInfo
  { sriLogicalResourceId   :: !Text
  , sriPhysicalResourceId  :: !(Maybe Text)
  , sriResourceType        :: !Text
  , sriResourceStatus      :: !Text
  , sriResourceStatusReason :: !(Maybe Text)
  , sriLastUpdated         :: !(Maybe UTCTime)
  } deriving stock (Show, Eq)

data StackOutputInfo = StackOutputInfo
  { soiOutputKey   :: !Text
  , soiOutputValue :: !Text
  , soiDescription :: !(Maybe Text)
  , soiExportName  :: !(Maybe Text)
  } deriving stock (Show, Eq)

data StackExportInfo = StackExportInfo
  { seiName             :: !Text
  , seiValue            :: !Text
  , seiExportingStackId :: !Text
  , seiImportingStacks  :: ![Text]
  } deriving stock (Show, Eq)

data StackStatusInfo = StackStatusInfo
  { ssiStatus       :: !Text
  , ssiStatusReason :: !(Maybe Text)
  , ssiTimestamp    :: !(Maybe UTCTime)
  } deriving stock (Show, Eq)

data StackContents = StackContents
  { scResources         :: ![StackResourceInfo]
  , scOutputs           :: ![StackOutputInfo]
  , scExports           :: ![StackExportInfo]
  , scCurrentStatus     :: !StackStatusInfo
  , scPendingChangesets :: ![ChangeSetInfo]
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Changesets
------------------------------------------------------------------------

data ChangeSetInfo = ChangeSetInfo
  { csiChangeSetName   :: !Text
  , csiChangeSetId     :: !Text
  , csiStackId         :: !Text
  , csiStackName       :: !Text
  , csiDescription     :: !(Maybe Text)
  , csiStatus          :: !Text
  , csiStatusReason    :: !(Maybe Text)
  , csiCreationTime    :: !(Maybe UTCTime)
  , csiExecutionStatus :: !(Maybe Text)
  , csiChanges         :: ![ChangeInfo]
  } deriving stock (Show, Eq)

data ChangeInfo = ChangeInfo
  { ciAction             :: !Text
  , ciLogicalResourceId  :: !Text
  , ciPhysicalResourceId :: !(Maybe Text)
  , ciResourceType       :: !Text
  , ciReplacement        :: !(Maybe Text)
  , ciScope              :: !(Maybe [Text])
  , ciDetails            :: ![ChangeDetail]
  } deriving stock (Show, Eq)

data ChangeDetail = ChangeDetail
  { cdTarget        :: !Text
  , cdEvaluation    :: !(Maybe Text)
  , cdChangeSource  :: !(Maybe Text)
  , cdCausingEntity :: !(Maybe Text)
  } deriving stock (Show, Eq)

data ChangeSetCreationResult = ChangeSetCreationResult
  { csrChangesetName     :: !Text
  , csrStackName         :: !Text
  , csrChangesetType     :: !Text
  , csrStatus            :: !Text
  , csrConsoleUrl        :: !Text
  , csrHasChanges        :: !Bool
  , csrPendingChangesets :: ![ChangeSetInfo]
  , csrNextSteps         :: ![Text]
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Status & results
------------------------------------------------------------------------

data StatusLevel = LevelInfo | LevelWarning | LevelError | LevelSuccess
  deriving stock (Show, Eq, Ord)

data StatusUpdate = StatusUpdate
  { suMessage   :: !Text
  , suTimestamp :: !UTCTime
  , suLevel     :: !StatusLevel
  } deriving stock (Show, Eq)

data CommandResult = CommandResult
  { crSuccess        :: !Bool
  , crElapsedSeconds :: !Int
  , crMessage        :: !(Maybe Text)
  , crExitCode       :: !Int
  } deriving stock (Show, Eq)

data CommandSummaryResult = SummarySuccess | SummaryFailure
  deriving stock (Show, Eq, Ord)

data FinalCommandSummary = FinalCommandSummary
  { fcsResult         :: !CommandSummaryResult
  , fcsElapsedSeconds :: !Int
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Stack listing
------------------------------------------------------------------------

data StackListColumn
  = ColName
  | ColStatus
  | ColTime
  | ColTags
  | ColStatusReason
  | ColTerminationProtection
  | ColEnvironment
  deriving stock (Show, Eq, Ord)

data StackListDisplay = StackListDisplay
  { sldStacks         :: ![StackListEntry]
  , sldShowTags       :: !Bool
  , sldFiltersApplied :: ![Text]
  , sldColumns        :: ![StackListColumn]
  , sldQueryMode      :: !Bool
  } deriving stock (Show, Eq)

data StackListEntry = StackListEntry
  { sleStackName             :: !Text
  , sleStackStatus           :: !Text
  , sleCreationTime          :: !(Maybe UTCTime)
  , sleLastUpdatedTime       :: !(Maybe UTCTime)
  , sleTags                  :: !(Map Text Text)
  , sleStatusReason          :: !(Maybe Text)
  , sleTerminationProtection :: !Bool
  , sleEnvironmentType       :: !(Maybe Text)
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Errors
------------------------------------------------------------------------

data ErrorDetails
  = ErrorGeneric !(Maybe Text)
  | ErrorStackAbsent !StackAbsentInfo
  deriving stock (Show, Eq)

data ErrorInfo = ErrorInfo
  { eiErrorType    :: !Text
  , eiMessage      :: !Text
  , eiTimestamp    :: !UTCTime
  , eiSuggestions  :: ![Text]
  , eiErrorDetails :: !ErrorDetails
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Operation lifecycle
------------------------------------------------------------------------

data OperationCompleteInfo = OperationCompleteInfo
  { ociElapsedSeconds       :: !Int
  , ociOperationStartTime   :: !UTCTime
  , ociSkipRemainingSections :: !Bool
  } deriving stock (Show, Eq)

data InactivityTimeoutInfo = InactivityTimeoutInfo
  { itiTimeoutSeconds     :: !Int
  , itiElapsedSeconds     :: !Int
  , itiOperationStartTime :: !UTCTime
  } deriving stock (Show, Eq)

data StackChangeDetails = StackChangeDetails
  { scdChangeType :: !StackChangeType
  , scdStackName  :: !Text
  } deriving stock (Show, Eq)

data StackAbsentInfo = StackAbsentInfo
  { saiStackName   :: !Text
  , saiEnvironment :: !Text
  , saiRegion      :: !Text
  , saiAccount     :: !Text
  , saiAuthArn     :: !Text
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Drift
------------------------------------------------------------------------

data StackDrift = StackDrift
  { sdrDriftedResources :: ![DriftedResource]
  } deriving stock (Show, Eq)

data DriftedResource = DriftedResource
  { drLogicalResourceId   :: !Text
  , drPhysicalResourceId  :: !Text
  , drResourceType        :: !Text
  , drDriftStatus         :: !Text
  , drPropertyDifferences :: ![PropertyDifference]
  } deriving stock (Show, Eq)

data PropertyDifference = PropertyDifference
  { pdPropertyPath   :: !Text
  , pdExpectedValue  :: !(Maybe Text)
  , pdActualValue    :: !(Maybe Text)
  , pdDifferenceType :: !(Maybe Text)
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Cost & templates
------------------------------------------------------------------------

data CostEstimateInfo = CostEstimateInfo
  { ceiUrl          :: !Text
  , ceiStackName    :: !(Maybe Text)
  , ceiTemplateFile :: !(Maybe Text)
  } deriving stock (Show, Eq)

newtype CostEstimate = CostEstimate
  { ceInfo :: CostEstimateInfo
  } deriving stock (Show, Eq)

data StackTemplate = StackTemplate
  { stStderrLines  :: ![Text]
  , stTemplateBody :: !Text
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Approval
------------------------------------------------------------------------

data ApprovalRequestResult = ApprovalRequestResult
  { arrTemplateLocation :: !Text
  , arrPendingLocation  :: !Text
  , arrAlreadyApproved  :: !Bool
  , arrNextSteps        :: ![Text]
  } deriving stock (Show, Eq)

data TemplateValidation = TemplateValidation
  { tvEnabled  :: !Bool
  , tvErrors   :: ![Text]
  , tvWarnings :: ![Text]
  } deriving stock (Show, Eq)

data ApprovalStatus = ApprovalStatus
  { apsPendingExists    :: !Bool
  , apsAlreadyApproved  :: !Bool
  , apsPendingLocation  :: !Text
  , apsApprovedLocation :: !(Maybe Text)
  } deriving stock (Show, Eq)

data TemplateDiff = TemplateDiff
  { tdDiffOutput   :: !Text
  , tdContextLines :: !Int
  , tdHasChanges   :: !Bool
  } deriving stock (Show, Eq)

data ApprovalResult = ApprovalResult
  { arApproved         :: !Bool
  , arApprovedLocation :: !(Maybe Text)
  , arLatestLocation   :: !(Maybe Text)
  , arCleanupCompleted :: !Bool
  } deriving stock (Show, Eq)

------------------------------------------------------------------------
-- Confirmation
------------------------------------------------------------------------

data ConfirmationRequest = ConfirmationRequest
  { cfrMessage :: !Text
  , cfrKey     :: !(Maybe Text)
  } deriving stock (Show, Eq)
