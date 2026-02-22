-- | JSON renderer for structured machine-readable output.
--
-- Outputs data in JSON Lines (JSONL) format, where each rendered piece
-- becomes a JSON object with type, timestamp, and data fields.
module Iidy.Output.Renderers.Json
  ( JsonRenderer(..)
  , JsonOptions(..)
  , defaultJsonOptions
  , newJsonRenderer
  , renderOutputDataJson
    -- * Value conversions (exported for testing)
  , metadataToValue
  , defToValue
  , eventToValue
  , eventWithTimingToValue
  , eventsDisplayToValue
  , contentsToValue
  , statusUpdateToValue
  , commandResultToValue
  , summaryToValue
  , stackListToValue
  , stackListEntryToValue
  , changesetResultToValue
  , driftToValue
  , errorInfoToValue
  , tokenInfoToValue
  , operationCompleteToValue
  , inactivityTimeoutToValue
  , changeDetailsToValue
  , absentInfoToValue
  , costEstimateToValue
  , approvalRequestToValue
  , templateValidationToValue
  , approvalStatusToValue
  , templateDiffToValue
  , approvalResultToValue
  , encodeValue
  ) where

import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Encode.Pretty as Pretty
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Data.Time (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import System.IO (stdout, hFlush, stderr)

import Iidy.Aws.ClientReqToken (TokenInfo(..), TokenSource(..), DerivedTokenInfo(..))
import Iidy.Cfn.Types (StackChangeType(..))
import Iidy.Output.Types

------------------------------------------------------------------------
-- Options
------------------------------------------------------------------------

data JsonOptions = JsonOptions
  { joIncludeTimestamps :: !Bool
  , joPrettyPrint       :: !Bool
  , joIncludeType       :: !Bool
  } deriving stock (Show, Eq)

defaultJsonOptions :: JsonOptions
defaultJsonOptions = JsonOptions
  { joIncludeTimestamps = True
  , joPrettyPrint       = False
  , joIncludeType       = True
  }

------------------------------------------------------------------------
-- Renderer
------------------------------------------------------------------------

data JsonRenderer = JsonRenderer
  { jrOptions :: !JsonOptions
  }

newJsonRenderer :: JsonOptions -> JsonRenderer
newJsonRenderer = JsonRenderer

------------------------------------------------------------------------
-- Main dispatch
------------------------------------------------------------------------

renderOutputDataJson :: JsonRenderer -> OutputData -> IO ()
renderOutputDataJson r = \case
  OdCommandMetadata meta         -> outputJson r "command_metadata" (metadataToValue meta)
  OdStackDefinition def showT    -> outputJson r "stack_definition" (object ["stack_definition" .= defToValue def, "show_times" .= showT])
  OdStackEvents evts             -> outputJson r "stack_events" (eventsDisplayToValue evts)
  OdStackContents contents       -> outputJson r "stack_contents" (contentsToValue contents)
  OdStatusUpdate upd             -> outputJson r "status_update" (statusUpdateToValue upd)
  OdCommandResult res            -> outputJson r "command_result" (commandResultToValue res)
  OdFinalCommandSummary summ     -> outputJson r "final_command_summary" (summaryToValue summ)
  OdStackList lst                ->
    if sldQueryMode lst
    then outputRawJson r (Aeson.toJSON (map stackListEntryToValue (sldStacks lst)))
    else outputJson r "stack_list" (stackListToValue lst)
  OdChangeSetResult cs           -> outputJson r "changeset_result" (changesetResultToValue cs)
  OdStackDrift drift             -> outputJson r "stack_drift" (driftToValue drift)
  OdError err                    -> outputJson r "error" (errorInfoToValue err)
  OdTokenInfo tok                -> outputJson r "token_info" (tokenInfoToValue tok)
  OdNewStackEvents evts          -> outputJson r "new_stack_events" (Aeson.toJSON (map eventWithTimingToValue evts))
  OdOperationComplete info       -> outputJson r "operation_complete" (operationCompleteToValue info)
  OdInactivityTimeout info       -> outputJson r "inactivity_timeout" (inactivityTimeoutToValue info)
  OdConfirmationPrompt req       -> do
    now <- getCurrentTime
    let val = object
          [ "type" .= ("confirmation_required" :: Text)
          , "message" .= cfrMessage req
          , "timestamp" .= iso8601Show now
          , "response" .= ("declined_non_interactive" :: Text)
          ]
    outputLine r (encodeValue (jrOptions r) val)
  OdStackChangeDetails details   -> outputJson r "stack_change_details" (changeDetailsToValue details)
  OdStackAbsentInfo info         -> outputJson r "stack_absent_info" (absentInfoToValue info)
  OdCostEstimate est             -> outputJson r "cost_estimate" (costEstimateToValue est)
  OdStackTemplate tmpl           -> do
    mapM_ (TIO.hPutStrLn stderr) (stStderrLines tmpl)
    TIO.putStrLn (stTemplateBody tmpl)
  OdApprovalRequestResult res    -> outputJson r "approval_request_result" (approvalRequestToValue res)
  OdTemplateValidation val       -> outputJson r "template_validation" (templateValidationToValue val)
  OdApprovalStatus st            -> outputJson r "approval_status" (approvalStatusToValue st)
  OdTemplateDiff diff            -> outputJson r "template_diff" (templateDiffToValue diff)
  OdApprovalResult res           -> outputJson r "approval_result" (approvalResultToValue res)

------------------------------------------------------------------------
-- JSON output helpers
------------------------------------------------------------------------

outputJson :: JsonRenderer -> Text -> Value -> IO ()
outputJson r typeName val = do
  now <- getCurrentTime
  let opts = jrOptions r
      wrapper = case (joIncludeTimestamps opts, joIncludeType opts) of
        (True, True) -> object ["type" .= typeName, "timestamp" .= iso8601Show now, "data" .= val]
        (False, True) -> object ["type" .= typeName, "data" .= val]
        (True, False) -> object ["timestamp" .= iso8601Show now, "data" .= val]
        (False, False) -> val
  outputLine r (encodeValue opts wrapper)

outputRawJson :: JsonRenderer -> Value -> IO ()
outputRawJson r val = do
  let encoded = if joPrettyPrint (jrOptions r)
                then TL.toStrict (TLE.decodeUtf8 (Pretty.encodePretty val))
                else TL.toStrict (TLE.decodeUtf8 (Aeson.encode val))
  TIO.putStrLn encoded
  hFlush stdout

outputLine :: JsonRenderer -> Text -> IO ()
outputLine _r text = do
  TIO.putStrLn text
  hFlush stdout

encodeValue :: JsonOptions -> Value -> Text
encodeValue opts val =
  if joPrettyPrint opts
  then TL.toStrict (TLE.decodeUtf8 (Aeson.encode val))  -- compact for now
  else TL.toStrict (TLE.decodeUtf8 (Aeson.encode val))

------------------------------------------------------------------------
-- Value conversions (OutputData types -> aeson Value)
------------------------------------------------------------------------

metadataToValue :: CommandMetadata -> Value
metadataToValue m = object
  [ "iidy_environment" .= cmEnvironment m
  , "region" .= cmRegion m
  , "profile" .= cmProfile m
  , "cli_arguments" .= cmCliArguments m
  , "iam_service_role" .= cmIamServiceRole m
  , "current_iam_principal" .= cmCurrentIamPrincipal m
  , "credential_source" .= cmCredentialSource m
  , "iidy_version" .= cmVersion m
  , "primary_token" .= tokenInfoToValue (cmPrimaryToken m)
  , "derived_tokens" .= map tokenInfoToValue (cmDerivedTokens m)
  ]

tokenInfoToValue :: TokenInfo -> Value
tokenInfoToValue t = object
  [ "value" .= tiValue t
  , "source" .= tokenSourceToValue (tiSource t)
  , "operation_id" .= tiOperationId t
  ]

tokenSourceToValue :: TokenSource -> Value
tokenSourceToValue = \case
  UserProvided -> object ["type" .= ("user_provided" :: Text)]
  AutoGenerated -> object ["type" .= ("auto_generated" :: Text)]
  Derived dti -> object
    [ "type" .= ("derived" :: Text)
    , "from" .= dtiFrom dti
    , "step" .= dtiStep dti
    ]

defToValue :: StackDefinition -> Value
defToValue d = object
  [ "name" .= sdName d
  , "stackset_name" .= sdStacksetName d
  , "description" .= sdDescription d
  , "status" .= sdStatus d
  , "status_reason" .= sdStatusReason d
  , "capabilities" .= sdCapabilities d
  , "service_role" .= sdServiceRole d
  , "tags" .= sdTags d
  , "parameters" .= sdParameters d
  , "disable_rollback" .= sdDisableRollback d
  , "termination_protection" .= sdTerminationProtection d
  , "creation_time" .= sdCreationTime d
  , "last_updated_time" .= sdLastUpdatedTime d
  , "timeout_in_minutes" .= sdTimeoutInMinutes d
  , "notification_arns" .= sdNotificationArns d
  , "stack_policy" .= sdStackPolicy d
  , "arn" .= sdArn d
  , "console_url" .= sdConsoleUrl d
  , "region" .= sdRegion d
  ]

eventToValue :: StackEvent -> Value
eventToValue e = object
  [ "event_id" .= seEventId e
  , "stack_id" .= seStackId e
  , "stack_name" .= seStackName e
  , "logical_resource_id" .= seLogicalResourceId e
  , "physical_resource_id" .= sePhysicalResourceId e
  , "resource_type" .= seResourceType e
  , "timestamp" .= seTimestamp e
  , "resource_status" .= seResourceStatus e
  , "resource_status_reason" .= seResourceStatusReason e
  , "resource_properties" .= seResourceProperties e
  , "client_request_token" .= seClientRequestToken e
  ]

eventWithTimingToValue :: StackEventWithTiming -> Value
eventWithTimingToValue ewt = object
  [ "event" .= eventToValue (sewEvent ewt)
  , "duration_seconds" .= sewDurationSeconds ewt
  ]

eventsDisplayToValue :: StackEventsDisplay -> Value
eventsDisplayToValue d = object
  [ "title" .= sedTitle d
  , "events" .= map eventWithTimingToValue (sedEvents d)
  , "max_events" .= sedMaxEvents d
  , "truncated" .= fmap truncInfoToValue (sedTruncated d)
  ]

truncInfoToValue :: TruncationInfo -> Value
truncInfoToValue ti = object
  [ "shown" .= truncShown ti
  , "total" .= truncTotal ti
  ]

resourceInfoToValue :: StackResourceInfo -> Value
resourceInfoToValue r = object
  [ "logical_resource_id" .= sriLogicalResourceId r
  , "physical_resource_id" .= sriPhysicalResourceId r
  , "resource_type" .= sriResourceType r
  , "resource_status" .= sriResourceStatus r
  , "resource_status_reason" .= sriResourceStatusReason r
  , "last_updated" .= sriLastUpdated r
  ]

outputInfoToValue :: StackOutputInfo -> Value
outputInfoToValue o = object
  [ "output_key" .= soiOutputKey o
  , "output_value" .= soiOutputValue o
  , "description" .= soiDescription o
  , "export_name" .= soiExportName o
  ]

exportInfoToValue :: StackExportInfo -> Value
exportInfoToValue e = object
  [ "name" .= seiName e
  , "value" .= seiValue e
  , "exporting_stack_id" .= seiExportingStackId e
  , "importing_stacks" .= seiImportingStacks e
  ]

statusInfoToValue :: StackStatusInfo -> Value
statusInfoToValue s = object
  [ "status" .= ssiStatus s
  , "status_reason" .= ssiStatusReason s
  , "timestamp" .= ssiTimestamp s
  ]

changeSetInfoToValue :: ChangeSetInfo -> Value
changeSetInfoToValue cs = object
  [ "change_set_name" .= csiChangeSetName cs
  , "change_set_id" .= csiChangeSetId cs
  , "stack_id" .= csiStackId cs
  , "stack_name" .= csiStackName cs
  , "description" .= csiDescription cs
  , "status" .= csiStatus cs
  , "status_reason" .= csiStatusReason cs
  , "creation_time" .= csiCreationTime cs
  , "execution_status" .= csiExecutionStatus cs
  , "changes" .= map changeInfoToValue (csiChanges cs)
  ]

changeInfoToValue :: ChangeInfo -> Value
changeInfoToValue c = object
  [ "action" .= ciAction c
  , "logical_resource_id" .= ciLogicalResourceId c
  , "physical_resource_id" .= ciPhysicalResourceId c
  , "resource_type" .= ciResourceType c
  , "replacement" .= ciReplacement c
  , "scope" .= ciScope c
  , "details" .= map changeDetailToValue (ciDetails c)
  ]

changeDetailToValue :: ChangeDetail -> Value
changeDetailToValue cd = object
  [ "target" .= cdTarget cd
  , "evaluation" .= cdEvaluation cd
  , "change_source" .= cdChangeSource cd
  , "causing_entity" .= cdCausingEntity cd
  ]

contentsToValue :: StackContents -> Value
contentsToValue c = object
  [ "resources" .= map resourceInfoToValue (scResources c)
  , "outputs" .= map outputInfoToValue (scOutputs c)
  , "exports" .= map exportInfoToValue (scExports c)
  , "current_status" .= statusInfoToValue (scCurrentStatus c)
  , "pending_changesets" .= map changeSetInfoToValue (scPendingChangesets c)
  ]

statusUpdateToValue :: StatusUpdate -> Value
statusUpdateToValue u = object
  [ "message" .= suMessage u
  , "timestamp" .= suTimestamp u
  , "level" .= levelToText (suLevel u)
  ]
  where
    levelToText :: StatusLevel -> Text
    levelToText LevelInfo    = "info"
    levelToText LevelWarning = "warning"
    levelToText LevelError   = "error"
    levelToText LevelSuccess = "success"

commandResultToValue :: CommandResult -> Value
commandResultToValue r = object
  [ "success" .= crSuccess r
  , "elapsed_seconds" .= crElapsedSeconds r
  , "message" .= crMessage r
  , "exit_code" .= crExitCode r
  ]

summaryToValue :: FinalCommandSummary -> Value
summaryToValue s = object
  [ "result" .= case fcsResult s of
      SummarySuccess -> "success" :: Text
      SummaryFailure -> "failure"
  , "elapsed_seconds" .= fcsElapsedSeconds s
  ]

stackListEntryToValue :: StackListEntry -> Value
stackListEntryToValue e = object
  [ "stack_name" .= sleStackName e
  , "stack_status" .= sleStackStatus e
  , "creation_time" .= sleCreationTime e
  , "last_updated_time" .= sleLastUpdatedTime e
  , "tags" .= sleTags e
  , "status_reason" .= sleStatusReason e
  , "termination_protection" .= sleTerminationProtection e
  , "environment_type" .= sleEnvironmentType e
  ]

stackListToValue :: StackListDisplay -> Value
stackListToValue l = object
  [ "stacks" .= map stackListEntryToValue (sldStacks l)
  , "show_tags" .= sldShowTags l
  , "filters_applied" .= sldFiltersApplied l
  , "columns" .= map columnToText (sldColumns l)
  , "query_mode" .= sldQueryMode l
  ]
  where
    columnToText :: StackListColumn -> Text
    columnToText ColName = "name"
    columnToText ColStatus = "status"
    columnToText ColTime = "time"
    columnToText ColTags = "tags"
    columnToText ColStatusReason = "status_reason"
    columnToText ColTerminationProtection = "termination_protection"
    columnToText ColEnvironment = "environment"

changesetResultToValue :: ChangeSetCreationResult -> Value
changesetResultToValue cs = object
  [ "changeset_name" .= csrChangesetName cs
  , "stack_name" .= csrStackName cs
  , "changeset_type" .= csrChangesetType cs
  , "status" .= csrStatus cs
  , "console_url" .= csrConsoleUrl cs
  , "has_changes" .= csrHasChanges cs
  , "pending_changesets" .= map changeSetInfoToValue (csrPendingChangesets cs)
  , "next_steps" .= csrNextSteps cs
  ]

driftToValue :: StackDrift -> Value
driftToValue d = object
  [ "drifted_resources" .= map driftedResourceToValue (sdrDriftedResources d)
  ]

driftedResourceToValue :: DriftedResource -> Value
driftedResourceToValue dr = object
  [ "logical_resource_id" .= drLogicalResourceId dr
  , "physical_resource_id" .= drPhysicalResourceId dr
  , "resource_type" .= drResourceType dr
  , "drift_status" .= drDriftStatus dr
  , "property_differences" .= map propertyDiffToValue (drPropertyDifferences dr)
  ]

propertyDiffToValue :: PropertyDifference -> Value
propertyDiffToValue pd = object
  [ "property_path" .= pdPropertyPath pd
  , "expected_value" .= pdExpectedValue pd
  , "actual_value" .= pdActualValue pd
  , "difference_type" .= pdDifferenceType pd
  ]

errorInfoToValue :: ErrorInfo -> Value
errorInfoToValue e = object
  [ "error_type" .= eiErrorType e
  , "message" .= eiMessage e
  , "timestamp" .= eiTimestamp e
  , "suggestions" .= eiSuggestions e
  , "error_details" .= errorDetailsToValue (eiErrorDetails e)
  ]

errorDetailsToValue :: ErrorDetails -> Value
errorDetailsToValue = \case
  ErrorGeneric mtext -> object ["type" .= ("generic" :: Text), "details" .= mtext]
  ErrorStackAbsent info -> object ["type" .= ("stack_absent" :: Text), "info" .= absentInfoToValue info]

operationCompleteToValue :: OperationCompleteInfo -> Value
operationCompleteToValue info = object
  [ "elapsed_seconds" .= ociElapsedSeconds info
  , "operation_start_time" .= ociOperationStartTime info
  , "skip_remaining_sections" .= ociSkipRemainingSections info
  ]

inactivityTimeoutToValue :: InactivityTimeoutInfo -> Value
inactivityTimeoutToValue info = object
  [ "timeout_seconds" .= itiTimeoutSeconds info
  , "elapsed_seconds" .= itiElapsedSeconds info
  , "operation_start_time" .= itiOperationStartTime info
  ]

changeDetailsToValue :: StackChangeDetails -> Value
changeDetailsToValue d = object
  [ "change_type" .= changeTypeToText (scdChangeType d)
  , "stack_name" .= scdStackName d
  ]
  where
    changeTypeToText :: StackChangeType -> Text
    changeTypeToText ChangeCreate = "create"
    changeTypeToText (ChangeUpdateWithChanges _) = "update_with_changes"
    changeTypeToText ChangeUpdateNoChanges = "update_no_changes"

absentInfoToValue :: StackAbsentInfo -> Value
absentInfoToValue info = object
  [ "stack_name" .= saiStackName info
  , "environment" .= saiEnvironment info
  , "region" .= saiRegion info
  , "account" .= saiAccount info
  , "auth_arn" .= saiAuthArn info
  ]

costEstimateToValue :: CostEstimate -> Value
costEstimateToValue est = object
  [ "url" .= ceiUrl (ceInfo est)
  , "stack_name" .= ceiStackName (ceInfo est)
  , "template_file" .= ceiTemplateFile (ceInfo est)
  ]

approvalRequestToValue :: ApprovalRequestResult -> Value
approvalRequestToValue r = object
  [ "template_location" .= arrTemplateLocation r
  , "pending_location" .= arrPendingLocation r
  , "already_approved" .= arrAlreadyApproved r
  , "next_steps" .= arrNextSteps r
  ]

templateValidationToValue :: TemplateValidation -> Value
templateValidationToValue v = object
  [ "enabled" .= tvEnabled v
  , "errors" .= tvErrors v
  , "warnings" .= tvWarnings v
  ]

approvalStatusToValue :: ApprovalStatus -> Value
approvalStatusToValue s = object
  [ "pending_exists" .= apsPendingExists s
  , "already_approved" .= apsAlreadyApproved s
  , "pending_location" .= apsPendingLocation s
  , "approved_location" .= apsApprovedLocation s
  ]

templateDiffToValue :: TemplateDiff -> Value
templateDiffToValue d = object
  [ "diff_output" .= tdDiffOutput d
  , "context_lines" .= tdContextLines d
  , "has_changes" .= tdHasChanges d
  ]

approvalResultToValue :: ApprovalResult -> Value
approvalResultToValue r = object
  [ "approved" .= arApproved r
  , "approved_location" .= arApprovedLocation r
  , "latest_location" .= arLatestLocation r
  , "cleanup_completed" .= arCleanupCompleted r
  ]
