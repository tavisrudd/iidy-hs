module Test.JsonRendererTest (jsonRendererTests) where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Cfn.Status (StackStatus (..))

import Iidy.Cfn.Types (StackChangeType (..))
import Iidy.Output.Renderers.Json (
    JsonOptions (..),
    absentInfoToValue,
    approvalRequestToValue,
    approvalResultToValue,
    approvalStatusToValue,
    changeDetailsToValue,
    changesetResultToValue,
    commandResultToValue,
    contentsToValue,
    costEstimateToValue,
    defToValue,
    defaultJsonOptions,
    driftToValue,
    encodeValue,
    errorInfoToValue,
    eventToValue,
    eventWithTimingToValue,
    eventsDisplayToValue,
    inactivityTimeoutToValue,
    metadataToValue,
    operationCompleteToValue,
    stackListEntryToValue,
    stackListToValue,
    statusUpdateToValue,
    summaryToValue,
    templateDiffToValue,
    templateValidationToValue,
    tokenInfoToValue,
 )
import Iidy.Output.Types
import Test.Shared

jsonRendererTests :: [TestTree]
jsonRendererTests =
    [ testCase "metadataToValue - has all fields" $ do
        let meta =
                CommandMetadata
                    { cmEnvironment = "production"
                    , cmRegion = "us-east-1"
                    , cmProfile = Just "default"
                    , cmCliArguments = Map.fromList [("stack-args", "stack.yaml")]
                    , cmIamServiceRole = Nothing
                    , cmCurrentIamPrincipal = "arn:aws:iam::123:user/dev"
                    , cmCredentialSource = "environment"
                    , cmVersion = "1.0.0"
                    , cmPrimaryToken = testTokenInfo
                    , cmDerivedTokens = []
                    }
            val = metadataToValue meta
        assertBool "is object" (isObject val)
        assertEqual "region" (Just (String "us-east-1")) (jsonLookup "region" val)
        assertEqual "environment" (Just (String "production")) (jsonLookup "iidy_environment" val)
        assertEqual "version" (Just (String "1.0.0")) (jsonLookup "iidy_version" val)
    , testCase "defToValue - contains stack fields" $ do
        let val = defToValue testStackDef
        assertEqual "name" (Just (String "my-stack")) (jsonLookup "name" val)
        assertEqual "status" (Just (String "CREATE_COMPLETE")) (jsonLookup "status" val)
        assertEqual "description" (Just (String "Test stack")) (jsonLookup "description" val)
        assertEqual "region" (Just (String "us-east-1")) (jsonLookup "region" val)
        assertEqual "termination_protection" (Just (Aeson.Bool True)) (jsonLookup "termination_protection" val)
    , testCase "eventToValue - has event fields" $ do
        let val = eventToValue testStackEvent
        assertEqual "event_id" (Just (String "evt-001")) (jsonLookup "event_id" val)
        assertEqual "logical_resource_id" (Just (String "MyBucket")) (jsonLookup "logical_resource_id" val)
        assertEqual "resource_type" (Just (String "AWS::S3::Bucket")) (jsonLookup "resource_type" val)
        assertEqual "resource_status" (Just (String "CREATE_COMPLETE")) (jsonLookup "resource_status" val)
    , testCase "eventWithTimingToValue - wraps event with duration" $ do
        let val = eventWithTimingToValue testEventWithTiming
        assertBool "has event" (isJust (jsonLookup "event" val))
        assertEqual "duration" (Just (Number 45)) (jsonLookup "duration_seconds" val)
    , testCase "eventsDisplayToValue - has title and events" $ do
        let display =
                StackEventsDisplay
                    { sedTitle = "Recent Events"
                    , sedEvents = [testEventWithTiming]
                    , sedMaxEvents = Just 50
                    , sedTruncated = Nothing
                    }
            val = eventsDisplayToValue display
        assertEqual "title" (Just (String "Recent Events")) (jsonLookup "title" val)
    , testCase "statusUpdateToValue - has level and message" $ do
        let val = statusUpdateToValue testStatusUpdate
        assertEqual "message" (Just (String "Stack creation in progress")) (jsonLookup "message" val)
        assertEqual "level" (Just (String "info")) (jsonLookup "level" val)
    , testCase "statusUpdateToValue - warning level" $ do
        let upd = testStatusUpdate{suLevel = LevelWarning}
            val = statusUpdateToValue upd
        assertEqual "level" (Just (String "warning")) (jsonLookup "level" val)
    , testCase "statusUpdateToValue - error level" $ do
        let upd = testStatusUpdate{suLevel = LevelError}
            val = statusUpdateToValue upd
        assertEqual "level" (Just (String "error")) (jsonLookup "level" val)
    , testCase "statusUpdateToValue - success level" $ do
        let upd = testStatusUpdate{suLevel = LevelSuccess}
            val = statusUpdateToValue upd
        assertEqual "level" (Just (String "success")) (jsonLookup "level" val)
    , testCase "commandResultToValue - success" $ do
        let val = commandResultToValue testCommandResult
        assertEqual "success" (Just (Aeson.Bool True)) (jsonLookup "success" val)
        assertEqual "elapsed" (Just (Number 120)) (jsonLookup "elapsed_seconds" val)
        assertEqual "exit_code" (Just (Number 0)) (jsonLookup "exit_code" val)
    , testCase "summaryToValue - success" $ do
        let summ = FinalCommandSummary{fcsResult = SummarySuccess, fcsElapsedSeconds = 60}
            val = summaryToValue summ
        assertEqual "result" (Just (String "success")) (jsonLookup "result" val)
        assertEqual "elapsed" (Just (Number 60)) (jsonLookup "elapsed_seconds" val)
    , testCase "summaryToValue - failure" $ do
        let summ = FinalCommandSummary{fcsResult = SummaryFailure, fcsElapsedSeconds = 10}
            val = summaryToValue summ
        assertEqual "result" (Just (String "failure")) (jsonLookup "result" val)
    , testCase "stackListEntryToValue - has stack fields" $ do
        let val = stackListEntryToValue testStackListEntry
        assertEqual "stack_name" (Just (String "my-stack")) (jsonLookup "stack_name" val)
        assertEqual "stack_status" (Just (String "CREATE_COMPLETE")) (jsonLookup "stack_status" val)
        assertEqual "termination_protection" (Just (Aeson.Bool True)) (jsonLookup "termination_protection" val)
        assertEqual "environment_type" (Just (String "production")) (jsonLookup "environment_type" val)
    , testCase "stackListToValue - has stacks and columns" $ do
        let display =
                StackListDisplay
                    { sldStacks = [testStackListEntry]
                    , sldShowTags = True
                    , sldFiltersApplied = ["status:CREATE_COMPLETE"]
                    , sldColumns = [ColName, ColStatus, ColTags]
                    , sldQueryMode = False
                    }
            val = stackListToValue display
        assertEqual "show_tags" (Just (Aeson.Bool True)) (jsonLookup "show_tags" val)
        assertEqual "query_mode" (Just (Aeson.Bool False)) (jsonLookup "query_mode" val)
    , testCase "driftToValue - has drifted resources" $ do
        let drift =
                StackDrift
                    { sdrDriftedResources =
                        [ DriftedResource
                            { drLogicalResourceId = "MyBucket"
                            , drPhysicalResourceId = "bucket-123"
                            , drResourceType = "AWS::S3::Bucket"
                            , drDriftStatus = "MODIFIED"
                            , drPropertyDifferences =
                                [ PropertyDifference
                                    { pdPropertyPath = "/BucketName"
                                    , pdExpectedValue = Just "expected-name"
                                    , pdActualValue = Just "actual-name"
                                    , pdDifferenceType = Just "NOT_EQUAL"
                                    }
                                ]
                            }
                        ]
                    }
            val = driftToValue drift
        assertBool "has drifted_resources" (isJust (jsonLookup "drifted_resources" val))
    , testCase "errorInfoToValue - has error fields" $ do
        let val = errorInfoToValue testErrorInfo
        assertEqual "error_type" (Just (String "ValidationError")) (jsonLookup "error_type" val)
        assertEqual "message" (Just (String "Template format error")) (jsonLookup "message" val)
    , testCase "tokenInfoToValue - auto-generated" $ do
        let val = tokenInfoToValue testTokenInfo
        assertEqual "value" (Just (String "tok-abc123")) (jsonLookup "value" val)
        assertEqual "operation_id" (Just (String "op-001")) (jsonLookup "operation_id" val)
    , testCase "operationCompleteToValue - has elapsed" $ do
        let info =
                OperationCompleteInfo
                    { ociElapsedSeconds = 300
                    , ociOperationStartTime = testTimestamp
                    , ociSkipRemainingSections = False
                    }
            val = operationCompleteToValue info
        assertEqual "elapsed" (Just (Number 300)) (jsonLookup "elapsed_seconds" val)
    , testCase "inactivityTimeoutToValue - has timeout" $ do
        let info =
                InactivityTimeoutInfo
                    { itiTimeoutSeconds = 600
                    , itiElapsedSeconds = 605
                    , itiOperationStartTime = testTimestamp
                    }
            val = inactivityTimeoutToValue info
        assertEqual "timeout" (Just (Number 600)) (jsonLookup "timeout_seconds" val)
        assertEqual "elapsed" (Just (Number 605)) (jsonLookup "elapsed_seconds" val)
    , testCase "changeDetailsToValue - create" $ do
        let details = StackChangeDetails{scdChangeType = ChangeCreate, scdStackName = "new-stack"}
            val = changeDetailsToValue details
        assertEqual "change_type" (Just (String "create")) (jsonLookup "change_type" val)
        assertEqual "stack_name" (Just (String "new-stack")) (jsonLookup "stack_name" val)
    , testCase "absentInfoToValue - has all fields" $ do
        let val = absentInfoToValue testAbsentInfo
        assertEqual "stack_name" (Just (String "missing-stack")) (jsonLookup "stack_name" val)
        assertEqual "environment" (Just (String "development")) (jsonLookup "environment" val)
        assertEqual "region" (Just (String "us-west-2")) (jsonLookup "region" val)
    , testCase "costEstimateToValue - has URL" $ do
        let est = CostEstimate (CostEstimateInfo "https://calculator.aws" (Just "my-stack") (Just "template.yaml"))
            val = costEstimateToValue est
        assertEqual "url" (Just (String "https://calculator.aws")) (jsonLookup "url" val)
    , testCase "approvalRequestToValue - has locations" $ do
        let req =
                ApprovalRequestResult
                    { arrTemplateLocation = "s3://bucket/template.yaml"
                    , arrPendingLocation = "s3://bucket/pending/template.yaml"
                    , arrAlreadyApproved = False
                    , arrNextSteps = ["Review the template", "Run approval-review"]
                    }
            val = approvalRequestToValue req
        assertEqual "template_location" (Just (String "s3://bucket/template.yaml")) (jsonLookup "template_location" val)
        assertEqual "already_approved" (Just (Aeson.Bool False)) (jsonLookup "already_approved" val)
    , testCase "templateValidationToValue - with errors" $ do
        let tv = TemplateValidation{tvEnabled = True, tvErrors = ["Missing required property"], tvWarnings = []}
            val = templateValidationToValue tv
        assertEqual "enabled" (Just (Aeson.Bool True)) (jsonLookup "enabled" val)
    , testCase "approvalStatusToValue - pending" $ do
        let st =
                ApprovalStatus
                    { apsPendingExists = True
                    , apsAlreadyApproved = False
                    , apsPendingLocation = "s3://bucket/pending"
                    , apsApprovedLocation = Nothing
                    }
            val = approvalStatusToValue st
        assertEqual "pending_exists" (Just (Aeson.Bool True)) (jsonLookup "pending_exists" val)
    , testCase "templateDiffToValue - has changes" $ do
        let diff = TemplateDiff{tdDiffOutput = "--- a/t\n+++ b/t\n@@ -1 +1 @@\n-old\n+new", tdContextLines = 3, tdHasChanges = True}
            val = templateDiffToValue diff
        assertEqual "has_changes" (Just (Aeson.Bool True)) (jsonLookup "has_changes" val)
    , testCase "approvalResultToValue - approved" $ do
        let res =
                ApprovalResult
                    { arApproved = True
                    , arApprovedLocation = Just "s3://bucket/approved"
                    , arLatestLocation = Just "s3://bucket/latest"
                    , arCleanupCompleted = True
                    }
            val = approvalResultToValue res
        assertEqual "approved" (Just (Aeson.Bool True)) (jsonLookup "approved" val)
        assertEqual "cleanup_completed" (Just (Aeson.Bool True)) (jsonLookup "cleanup_completed" val)
    , testCase "encodeValue - produces valid JSON text" $ do
        let val = Aeson.object ["key" Aeson..= ("value" :: Text)]
            encoded = encodeValue defaultJsonOptions val
        assertBool "not empty" (not $ T.null encoded)
        assertBool "contains key" ("key" `T.isInfixOf` encoded)
    , testCase "JSON envelope with type wraps data" $ do
        let opts = defaultJsonOptions{joIncludeTimestamps = False}
            dataVal = statusUpdateToValue testStatusUpdate
            envelope = Aeson.object ["type" Aeson..= ("status_update" :: Text), "data" Aeson..= dataVal]
            encoded = encodeValue opts envelope
            parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
        case parsed of
            Nothing -> assertFailure ("Failed to parse JSON envelope: " <> T.unpack encoded)
            Just v -> do
                assertEqual "type" (Just (String "status_update")) (jsonLookup "type" v)
                assertBool "has data" (isJust (jsonLookup "data" v))
    , testCase "JSON envelope without type" $ do
        let opts = defaultJsonOptions{joIncludeTimestamps = False, joIncludeType = False}
            dataVal = statusUpdateToValue testStatusUpdate
            encoded = encodeValue opts dataVal
            parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
        case parsed of
            Nothing -> assertFailure "Failed to parse JSON"
            Just v -> assertEqual "no type field" Nothing (jsonLookup "type" v)
    , testCase "JSON envelope all OutputData types produce valid JSON" $ do
        let opts = defaultJsonOptions{joIncludeTimestamps = False}
            pairs :: [(Text, Value)]
            pairs =
                [
                    ( "command_metadata"
                    , metadataToValue
                        CommandMetadata
                            { cmEnvironment = "dev"
                            , cmRegion = "us-east-1"
                            , cmProfile = Nothing
                            , cmCliArguments = Map.empty
                            , cmIamServiceRole = Nothing
                            , cmCurrentIamPrincipal = "arn:test"
                            , cmCredentialSource = "env"
                            , cmVersion = "1.0"
                            , cmPrimaryToken = testTokenInfo
                            , cmDerivedTokens = []
                            }
                    )
                , ("status_update", statusUpdateToValue testStatusUpdate)
                , ("command_result", commandResultToValue testCommandResult)
                , ("final_command_summary", summaryToValue (FinalCommandSummary SummarySuccess 1))
                , ("error", errorInfoToValue testErrorInfo)
                , ("stack_definition", defToValue testStackDef)
                , ("stack_events", eventsDisplayToValue (StackEventsDisplay "Events" [testEventWithTiming] Nothing Nothing))
                , ("operation_complete", operationCompleteToValue (OperationCompleteInfo 60 testTimestamp False))
                , ("inactivity_timeout", inactivityTimeoutToValue (InactivityTimeoutInfo 300 305 testTimestamp))
                , ("cost_estimate", costEstimateToValue (CostEstimate (CostEstimateInfo "https://calc" Nothing Nothing)))
                , ("template_validation", templateValidationToValue (TemplateValidation True [] []))
                , ("template_diff", templateDiffToValue (TemplateDiff "diff" 3 True))
                , ("approval_result", approvalResultToValue (ApprovalResult True Nothing Nothing True))
                ]
        mapM_
            ( \(typeName, dataVal) -> do
                let envelope = Aeson.object ["type" Aeson..= typeName, "data" Aeson..= dataVal]
                    encoded = encodeValue opts envelope
                    parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
                case parsed of
                    Nothing -> assertFailure ("Failed to parse JSON for " <> T.unpack typeName <> ": " <> T.unpack encoded)
                    Just _ -> pure ()
            )
            pairs
    , testCase "contentsToValue - has resources and outputs" $ do
        let contents =
                StackContents
                    { scResources =
                        [StackResourceInfo "MyBucket" (Just "bucket-abc") "AWS::S3::Bucket" CreateComplete Nothing Nothing]
                    , scOutputs =
                        [StackOutputInfo "BucketArn" "arn:aws:s3:::bucket-abc" (Just "ARN of bucket") Nothing]
                    , scExports = []
                    , scCurrentStatus = StackStatusInfo CreateComplete Nothing Nothing
                    , scPendingChangesets = []
                    }
            val = contentsToValue contents
        assertBool "has resources" (isJust (jsonLookup "resources" val))
        assertBool "has outputs" (isJust (jsonLookup "outputs" val))
    , testCase "changesetResultToValue - has changeset fields" $ do
        let cs =
                ChangeSetCreationResult
                    { csrChangesetName = "cs-001"
                    , csrStackName = "my-stack"
                    , csrChangesetType = "CREATE"
                    , csrStatus = "CREATE_COMPLETE"
                    , csrConsoleUrl = "https://console.aws.amazon.com"
                    , csrHasChanges = True
                    , csrPendingChangesets = []
                    , csrNextSteps = ["exec-changeset cs-001"]
                    }
            val = changesetResultToValue cs
        assertEqual "changeset_name" (Just (String "cs-001")) (jsonLookup "changeset_name" val)
        assertEqual "has_changes" (Just (Aeson.Bool True)) (jsonLookup "has_changes" val)
    ]
