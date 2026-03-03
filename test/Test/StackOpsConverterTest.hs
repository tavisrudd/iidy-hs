{-# LANGUAGE DisambiguateRecordFields #-}
module Test.StackOpsConverterTest (stackOpsConverterTests) where

import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime(..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import qualified Amazonka.CloudFormation.Types as CF
import qualified Amazonka.CloudFormation.Types.StackResource as SR
import qualified Amazonka.CloudFormation.Types.Output as Out
import qualified Amazonka.CloudFormation.Types.ChangeSetSummary as CSS
import Amazonka.Data.Time (Time(..))
import Iidy.Cfn.Status (StackStatus(..))
import Iidy.Cfn.StackOperations (convertResource, convertOutput, convertChangeSetSummary)
import Iidy.Output.Types

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2024 1 1) 0

------------------------------------------------------------------------
-- Tests
------------------------------------------------------------------------

stackOpsConverterTests :: [TestTree]
stackOpsConverterTests =
  [ testGroup "convertResource"
    [ testCase "converts all fields from CF.StackResource" $ do
        let cfRes = (SR.newStackResource "MyBucket" "AWS::S3::Bucket" epoch CF.ResourceStatus_CREATE_COMPLETE)
              { SR.physicalResourceId = Just "my-bucket-phys-123"
              , SR.resourceStatusReason = Just "Resource creation complete"
              }
            result = convertResource cfRes
        sriLogicalResourceId result @?= "MyBucket"
        sriPhysicalResourceId result @?= Just "my-bucket-phys-123"
        sriResourceType result @?= "AWS::S3::Bucket"
        sriResourceStatus result @?= CreateComplete
        sriResourceStatusReason result @?= Just "Resource creation complete"
        sriLastUpdated result @?= Just epoch

    , testCase "minimal resource (no optional fields)" $ do
        let cfRes = SR.newStackResource "MyFunc" "AWS::Lambda::Function" epoch CF.ResourceStatus_DELETE_IN_PROGRESS
            result = convertResource cfRes
        sriLogicalResourceId result @?= "MyFunc"
        sriPhysicalResourceId result @?= Nothing
        sriResourceType result @?= "AWS::Lambda::Function"
        sriResourceStatus result @?= DeleteInProgress
        sriResourceStatusReason result @?= Nothing
        sriLastUpdated result @?= Just epoch

    , testCase "various resource statuses" $ do
        let mkRes st = SR.newStackResource "R" "AWS::EC2::Instance" epoch st
        sriResourceStatus (convertResource (mkRes CF.ResourceStatus_UPDATE_COMPLETE)) @?= UpdateComplete
        sriResourceStatus (convertResource (mkRes CF.ResourceStatus_CREATE_FAILED)) @?= CreateFailed
        sriResourceStatus (convertResource (mkRes CF.ResourceStatus_UPDATE_IN_PROGRESS)) @?= UpdateInProgress
    ]

  , testGroup "convertOutput"
    [ testCase "converts output with all fields" $ do
        let cfOut = CF.newOutput
              { Out.outputKey = Just "BucketName"
              , Out.outputValue = Just "my-bucket-abc"
              , Out.description = Just "The S3 bucket name"
              , Out.exportName = Just "MyBucketExport"
              }
        case convertOutput cfOut of
          Just result -> do
            soiOutputKey result @?= "BucketName"
            soiOutputValue result @?= "my-bucket-abc"
            soiDescription result @?= Just "The S3 bucket name"
            soiExportName result @?= Just "MyBucketExport"
          Nothing -> assertFailure "expected Just result"

    , testCase "returns Nothing when outputKey is missing" $ do
        let cfOut = CF.newOutput
              { Out.outputValue = Just "some-value"
              }
        convertOutput cfOut @?= Nothing

    , testCase "missing outputValue defaults to empty string" $ do
        let cfOut = CF.newOutput
              { Out.outputKey = Just "MyKey"
              }
        case convertOutput cfOut of
          Just result -> soiOutputValue result @?= ""
          Nothing -> assertFailure "expected Just result"

    , testCase "missing optional fields are Nothing" $ do
        let cfOut = CF.newOutput
              { Out.outputKey = Just "SimpleKey"
              , Out.outputValue = Just "val"
              }
        case convertOutput cfOut of
          Just result -> do
            soiDescription result @?= Nothing
            soiExportName result @?= Nothing
          Nothing -> assertFailure "expected Just result"
    ]

  , testGroup "convertChangeSetSummary"
    [ testCase "converts changeset with all fields" $ do
        let cfCS = CF.newChangeSetSummary
              { CSS.changeSetName = Just "my-changeset"
              , CSS.changeSetId = Just "arn:aws:cloudformation:us-east-1:123:changeSet/my-changeset/guid"
              , CSS.stackId = Just "arn:aws:cloudformation:us-east-1:123:stack/my-stack/guid"
              , CSS.stackName = Just "my-stack"
              , CSS.description = Just "Adding new bucket"
              , CSS.status = Just CF.ChangeSetStatus_CREATE_COMPLETE
              , CSS.statusReason = Just "Changeset created"
              , CSS.creationTime = Just (Time epoch)
              , CSS.executionStatus = Just CF.ExecutionStatus_AVAILABLE
              }
        case convertChangeSetSummary cfCS of
          Just result -> do
            csiChangeSetName result @?= "my-changeset"
            csiChangeSetId result @?= "arn:aws:cloudformation:us-east-1:123:changeSet/my-changeset/guid"
            csiStackId result @?= "arn:aws:cloudformation:us-east-1:123:stack/my-stack/guid"
            csiStackName result @?= "my-stack"
            csiDescription result @?= Just "Adding new bucket"
            csiStatus result @?= "CREATE_COMPLETE"
            csiStatusReason result @?= Just "Changeset created"
            csiCreationTime result @?= Just epoch
            csiExecutionStatus result @?= Just "AVAILABLE"
            csiChanges result @?= []
          Nothing -> assertFailure "expected Just result"

    , testCase "returns Nothing when changeSetName missing" $ do
        let cfCS = CF.newChangeSetSummary
              { CSS.changeSetId = Just "some-id"
              }
        convertChangeSetSummary cfCS @?= Nothing

    , testCase "returns Nothing when changeSetId missing" $ do
        let cfCS = CF.newChangeSetSummary
              { CSS.changeSetName = Just "some-name"
              }
        convertChangeSetSummary cfCS @?= Nothing

    , testCase "missing optional fields default correctly" $ do
        let cfCS = CF.newChangeSetSummary
              { CSS.changeSetName = Just "cs-minimal"
              , CSS.changeSetId = Just "cs-id-minimal"
              }
        case convertChangeSetSummary cfCS of
          Just result -> do
            csiStackId result @?= ""
            csiStackName result @?= ""
            csiDescription result @?= Nothing
            csiStatus result @?= ""
            csiStatusReason result @?= Nothing
            csiCreationTime result @?= Nothing
            csiExecutionStatus result @?= Nothing
          Nothing -> assertFailure "expected Just result"
    ]
  ]
