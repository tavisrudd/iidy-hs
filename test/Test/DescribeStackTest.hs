{-# LANGUAGE DisambiguateRecordFields #-}

module Test.DescribeStackTest (describeStackTests) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Amazonka.CloudFormation.Types qualified as CF
import Amazonka.CloudFormation.Types.Parameter qualified as Param
import Amazonka.CloudFormation.Types.Stack qualified as ST
import Amazonka.CloudFormation.Types.StackEvent qualified as SE
import Amazonka.Data.Time (Time (..))
import Iidy.Cfn.Operations.DescribeStack (buildConsoleUrl, buildEventsDisplay, calculateEventDurations, convertEvent, convertStack)
import Iidy.Cfn.Status (StackStatus (..))
import Iidy.Output.Types
import Test.Shared (mkEvent)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

at :: Int -> UTCTime
at secs = UTCTime (fromGregorian 2024 1 1) (fromIntegral secs)

------------------------------------------------------------------------
-- Tests
------------------------------------------------------------------------

describeStackTests :: [TestTree]
describeStackTests =
    [ testGroup
        "calculateEventDurations"
        [ testCase "matching IN_PROGRESS -> COMPLETE pair produces correct duration" $ do
            let events =
                    [ mkEvent "e1" "MyBucket" "AWS::S3::Bucket" CreateInProgress (Just (at 100))
                    , mkEvent "e2" "MyBucket" "AWS::S3::Bucket" CreateComplete (Just (at 145))
                    ]
                result = calculateEventDurations events
            -- The COMPLETE event should have a duration of 45 seconds
            case result of
                [_inProgress, complete] -> do
                    sewDurationSeconds complete @?= Just 45
                    -- The IN_PROGRESS event should have no duration
                    sewDurationSeconds _inProgress @?= Nothing
                other -> assertFailure $ "expected 2 results, got " ++ show (length other)
        , testCase "duration is at least 1 second (floor clamped)" $ do
            let events =
                    [ mkEvent "e1" "MyFunc" "AWS::Lambda::Function" CreateInProgress (Just (at 100))
                    , mkEvent "e2" "MyFunc" "AWS::Lambda::Function" CreateComplete (Just (at 100))
                    ]
                result = calculateEventDurations events
            -- Same timestamp -> max 1 (floor 0) = 1
            case result of
                [_, complete] -> sewDurationSeconds complete @?= Just 1
                other -> assertFailure $ "expected 2 results, got " ++ show (length other)
        , testCase "event with no matching start has Nothing duration" $ do
            let events =
                    [ mkEvent "e1" "MyBucket" "AWS::S3::Bucket" CreateComplete (Just (at 200))
                    ]
                result = calculateEventDurations events
            case result of
                [evt] -> sewDurationSeconds evt @?= Nothing
                other -> assertFailure $ "expected 1 result, got " ++ show (length other)
        , testCase "empty list produces empty result" $ do
            let result = calculateEventDurations []
            result @?= []
        , testCase "FAILED event also gets duration from IN_PROGRESS" $ do
            let events =
                    [ mkEvent "e1" "MyTable" "AWS::DynamoDB::Table" CreateInProgress (Just (at 50))
                    , mkEvent "e2" "MyTable" "AWS::DynamoDB::Table" CreateFailed (Just (at 80))
                    ]
                result = calculateEventDurations events
            case result of
                [_, failed] -> sewDurationSeconds failed @?= Just 30
                other -> assertFailure $ "expected 2 results, got " ++ show (length other)
        , testCase "multiple resources tracked independently" $ do
            let events =
                    [ mkEvent "e1" "BucketA" "AWS::S3::Bucket" CreateInProgress (Just (at 10))
                    , mkEvent "e2" "BucketB" "AWS::S3::Bucket" CreateInProgress (Just (at 20))
                    , mkEvent "e3" "BucketA" "AWS::S3::Bucket" CreateComplete (Just (at 30))
                    , mkEvent "e4" "BucketB" "AWS::S3::Bucket" CreateComplete (Just (at 50))
                    ]
                result = calculateEventDurations events
            -- BucketA: 30 - 10 = 20s, BucketB: 50 - 20 = 30s
            assertEqual "BucketA COMPLETE duration" (Just 20) (sewDurationSeconds (result !! 2))
            assertEqual "BucketB COMPLETE duration" (Just 30) (sewDurationSeconds (result !! 3))
        , testCase "events with no timestamp produce Nothing duration" $ do
            let events =
                    [ mkEvent "e1" "MyBucket" "AWS::S3::Bucket" CreateInProgress Nothing
                    , mkEvent "e2" "MyBucket" "AWS::S3::Bucket" CreateComplete Nothing
                    ]
                result = calculateEventDurations events
            case result of
                [inProg, complete] -> do
                    sewDurationSeconds inProg @?= Nothing
                    sewDurationSeconds complete @?= Nothing
                other -> assertFailure $ "expected 2 results, got " ++ show (length other)
        ]
    , testGroup
        "buildConsoleUrl"
        [ testCase "typical stack ARN and region" $ do
            let url = buildConsoleUrl "us-east-1" "arn:aws:cloudformation:us-east-1:123456789:stack/my-stack/guid-123"
            assertBool "starts with https" (T.isPrefixOf "https://" url)
            assertBool "contains region" (T.isInfixOf "us-east-1" url)
            assertBool "contains stackinfo path" (T.isInfixOf "#/stacks/stackinfo?stackId=" url)
        , testCase "ARN is percent-encoded in the URL" $ do
            let arn = "arn:aws:cloudformation:us-west-2:987654321:stack/test-stack/abc-def-123"
                url = buildConsoleUrl "us-west-2" arn
            -- Colons and slashes in the ARN should be percent-encoded
            assertBool "ARN colons encoded as %3A" (T.isInfixOf "%3A" url)
            assertBool "ARN slashes encoded as %2F" (T.isInfixOf "%2F" url)
            -- The raw ARN should NOT appear unencoded after the stackId= parameter
            let afterStackId = snd (T.breakOn "stackId=" url)
            assertBool "raw colon not in encoded ARN" (not (T.isInfixOf ":" (T.drop 8 afterStackId)))
        , testCase "different region appears in both host and query" $ do
            let url = buildConsoleUrl "eu-west-1" "arn:aws:cloudformation:eu-west-1:111:stack/s/g"
            -- Region should appear in the hostname
            assertBool "region in hostname" (T.isPrefixOf "https://eu-west-1.console.aws.amazon.com" url)
            -- Region should also appear in the query parameter
            assertBool "region in query" (T.isInfixOf "?region=eu-west-1" url)
        ]
    , testGroup
        "convertEvent"
        [ testCase "converts all required fields from CF.StackEvent" $ do
            let cfEvent =
                    (SE.newStackEvent "stack-id-123" "evt-001" "my-stack" epoch)
                        { SE.logicalResourceId = Just "MyBucket"
                        , SE.physicalResourceId = Just "my-bucket-phys"
                        , SE.resourceType = Just "AWS::S3::Bucket"
                        , SE.resourceStatus = Just CF.ResourceStatus_CREATE_COMPLETE
                        , SE.resourceStatusReason = Just "Resource creation complete"
                        , SE.resourceProperties = Just "{\"BucketName\":\"test\"}"
                        , SE.clientRequestToken = Just "tok-abc"
                        }
                result = convertEvent cfEvent
            seEventId result @?= "evt-001"
            seStackId result @?= "stack-id-123"
            seStackName result @?= "my-stack"
            seLogicalResourceId result @?= "MyBucket"
            sePhysicalResourceId result @?= Just "my-bucket-phys"
            seResourceType result @?= "AWS::S3::Bucket"
            seResourceStatus result @?= CreateComplete
            seResourceStatusReason result @?= Just "Resource creation complete"
            seResourceProperties result @?= Just "{\"BucketName\":\"test\"}"
            seClientRequestToken result @?= Just "tok-abc"
        , testCase "missing optional fields default correctly" $ do
            let cfEvent = SE.newStackEvent "stack-id" "evt-002" "stack" epoch
                result = convertEvent cfEvent
            seLogicalResourceId result @?= ""
            sePhysicalResourceId result @?= Nothing
            seResourceType result @?= ""
            seResourceStatus result @?= CreateFailed -- fallback when resourceStatus is Nothing
            seResourceStatusReason result @?= Nothing
            seResourceProperties result @?= Nothing
            seClientRequestToken result @?= Nothing
        , testCase "timestamp is extracted" $ do
            let ts = UTCTime (fromGregorian 2026 3 1) (12 * 3600)
                cfEvent = SE.newStackEvent "sid" "eid" "sn" ts
                result = convertEvent cfEvent
            seTimestamp result @?= Just ts
        ]
    , testGroup
        "convertStack"
        [ testCase "converts all fields from CF.Stack" $ do
            let cfStack =
                    (ST.newStack "my-stack" epoch CF.StackStatus_CREATE_COMPLETE)
                        { ST.stackId = Just "arn:aws:cloudformation:us-east-1:123:stack/my-stack/guid"
                        , ST.description = Just "Test stack description"
                        , ST.stackStatusReason = Just "Stack created"
                        , ST.capabilities = Just [CF.Capability_CAPABILITY_IAM, CF.Capability_CAPABILITY_NAMED_IAM]
                        , ST.roleARN = Just "arn:aws:iam::123:role/cfn-role"
                        , ST.tags = Just [CF.newTag "Env" "prod", CF.newTag "Team" "platform"]
                        , ST.parameters =
                            Just
                                [ CF.newParameter{Param.parameterKey = Just "VpcId", Param.parameterValue = Just "vpc-123"}
                                , CF.newParameter{Param.parameterKey = Just "Env", Param.parameterValue = Just "prod"}
                                ]
                        , ST.notificationARNs = Just ["arn:aws:sns:us-east-1:123:topic"]
                        , ST.disableRollback = Just True
                        , ST.enableTerminationProtection = Just True
                        , ST.timeoutInMinutes = Just 30
                        , ST.lastUpdatedTime = Just (Time epoch2)
                        }
                result = convertStack cfStack "us-east-1"
            sdName result @?= "my-stack"
            sdDescription result @?= Just "Test stack description"
            sdStatus result @?= CreateComplete
            sdStatusReason result @?= Just "Stack created"
            sdCapabilities result @?= ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]
            sdServiceRole result @?= Just "arn:aws:iam::123:role/cfn-role"
            Map.lookup "Env" (sdTags result) @?= Just "prod"
            Map.lookup "Team" (sdTags result) @?= Just "platform"
            Map.lookup "VpcId" (sdParameters result) @?= Just "vpc-123"
            Map.lookup "Env" (sdParameters result) @?= Just "prod"
            sdNotificationArns result @?= ["arn:aws:sns:us-east-1:123:topic"]
            sdDisableRollback result @?= True
            sdTerminationProtection result @?= True
            sdTimeoutInMinutes result @?= Just 30
            sdCreationTime result @?= Just epoch
            sdLastUpdatedTime result @?= Just epoch2
            sdArn result @?= "arn:aws:cloudformation:us-east-1:123:stack/my-stack/guid"
            sdRegion result @?= "us-east-1"
            assertBool "console URL contains region" (T.isInfixOf "us-east-1" (sdConsoleUrl result))
        , testCase "minimal stack (no optional fields)" $ do
            let cfStack = ST.newStack "minimal-stack" epoch CF.StackStatus_DELETE_COMPLETE
                result = convertStack cfStack "eu-west-1"
            sdName result @?= "minimal-stack"
            sdDescription result @?= Nothing
            sdStatus result @?= DeleteComplete
            sdStatusReason result @?= Nothing
            sdCapabilities result @?= []
            sdServiceRole result @?= Nothing
            sdTags result @?= Map.empty
            sdParameters result @?= Map.empty
            sdNotificationArns result @?= []
            sdDisableRollback result @?= False
            sdTerminationProtection result @?= False
            sdTimeoutInMinutes result @?= Nothing
            sdLastUpdatedTime result @?= Nothing
            sdStackPolicy result @?= Nothing
            sdArn result @?= ""
            sdRegion result @?= "eu-west-1"
        , testCase "StackSetName extracted from tags" $ do
            let cfStack =
                    (ST.newStack "ss-stack" epoch CF.StackStatus_CREATE_COMPLETE)
                        { ST.tags = Just [CF.newTag "StackSetName" "my-stackset"]
                        }
                result = convertStack cfStack "us-west-2"
            sdStacksetName result @?= Just "my-stackset"
        ]
    , testGroup
        "buildEventsDisplay"
        [ testCase "truncation info when events exceed max" $ do
            let events = [SE.newStackEvent "sid" ("e" <> T.pack (show i)) "sn" epoch | i <- [1 .. 10 :: Int]]
                result = buildEventsDisplay 5 events
            sedMaxEvents result @?= Just 5
            case sedTruncated result of
                Just ti -> do
                    truncShown ti @?= 5
                    truncTotal ti @?= 10
                Nothing -> assertFailure "expected truncation info"
        , testCase "no truncation when events within limit" $ do
            let events = [SE.newStackEvent "sid" ("e" <> T.pack (show i)) "sn" epoch | i <- [1 .. 3 :: Int]]
                result = buildEventsDisplay 10 events
            sedTruncated result @?= Nothing
        , testCase "title includes max count" $ do
            let result = buildEventsDisplay 25 []
            assertBool "title has count" (T.isInfixOf "25" (sedTitle result))
        ]
    ]
  where
    epoch :: UTCTime
    epoch = UTCTime (fromGregorian 2024 1 1) 0
    epoch2 :: UTCTime
    epoch2 = UTCTime (fromGregorian 2024 6 15) (10 * 3600)
