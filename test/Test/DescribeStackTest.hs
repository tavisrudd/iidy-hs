module Test.DescribeStackTest (describeStackTests) where

import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime(..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Cfn.Operations.DescribeStack (calculateEventDurations, buildConsoleUrl)
import Iidy.Output.Types (StackEventWithTiming(..))
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
  [ testGroup "calculateEventDurations"
    [ testCase "matching IN_PROGRESS -> COMPLETE pair produces correct duration" $ do
        let events =
              [ mkEvent "e1" "MyBucket" "AWS::S3::Bucket" "CREATE_IN_PROGRESS" (Just (at 100))
              , mkEvent "e2" "MyBucket" "AWS::S3::Bucket" "CREATE_COMPLETE" (Just (at 145))
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
              [ mkEvent "e1" "MyFunc" "AWS::Lambda::Function" "CREATE_IN_PROGRESS" (Just (at 100))
              , mkEvent "e2" "MyFunc" "AWS::Lambda::Function" "CREATE_COMPLETE" (Just (at 100))
              ]
            result = calculateEventDurations events
        -- Same timestamp -> max 1 (floor 0) = 1
        case result of
          [_, complete] -> sewDurationSeconds complete @?= Just 1
          other -> assertFailure $ "expected 2 results, got " ++ show (length other)

    , testCase "event with no matching start has Nothing duration" $ do
        let events =
              [ mkEvent "e1" "MyBucket" "AWS::S3::Bucket" "CREATE_COMPLETE" (Just (at 200))
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
              [ mkEvent "e1" "MyTable" "AWS::DynamoDB::Table" "CREATE_IN_PROGRESS" (Just (at 50))
              , mkEvent "e2" "MyTable" "AWS::DynamoDB::Table" "CREATE_FAILED" (Just (at 80))
              ]
            result = calculateEventDurations events
        case result of
          [_, failed] -> sewDurationSeconds failed @?= Just 30
          other -> assertFailure $ "expected 2 results, got " ++ show (length other)

    , testCase "multiple resources tracked independently" $ do
        let events =
              [ mkEvent "e1" "BucketA" "AWS::S3::Bucket" "CREATE_IN_PROGRESS" (Just (at 10))
              , mkEvent "e2" "BucketB" "AWS::S3::Bucket" "CREATE_IN_PROGRESS" (Just (at 20))
              , mkEvent "e3" "BucketA" "AWS::S3::Bucket" "CREATE_COMPLETE" (Just (at 30))
              , mkEvent "e4" "BucketB" "AWS::S3::Bucket" "CREATE_COMPLETE" (Just (at 50))
              ]
            result = calculateEventDurations events
        -- BucketA: 30 - 10 = 20s, BucketB: 50 - 20 = 30s
        assertEqual "BucketA COMPLETE duration" (Just 20) (sewDurationSeconds (result !! 2))
        assertEqual "BucketB COMPLETE duration" (Just 30) (sewDurationSeconds (result !! 3))

    , testCase "events with no timestamp produce Nothing duration" $ do
        let events =
              [ mkEvent "e1" "MyBucket" "AWS::S3::Bucket" "CREATE_IN_PROGRESS" Nothing
              , mkEvent "e2" "MyBucket" "AWS::S3::Bucket" "CREATE_COMPLETE" Nothing
              ]
            result = calculateEventDurations events
        case result of
          [inProg, complete] -> do
            sewDurationSeconds inProg @?= Nothing
            sewDurationSeconds complete @?= Nothing
          other -> assertFailure $ "expected 2 results, got " ++ show (length other)
    ]

  , testGroup "buildConsoleUrl"
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
  ]
