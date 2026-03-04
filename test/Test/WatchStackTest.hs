{-# LANGUAGE DisambiguateRecordFields #-}

module Test.WatchStackTest (watchStackTests) where

import Amazonka qualified
import Amazonka.CloudFormation.Types qualified as CF
import Amazonka.CloudFormation.Types.StackEvent qualified as SE
import Amazonka.Types qualified as AT
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime)
import Network.HTTP.Types.Status (status400)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Cfn.Context (allTerminalStatuses)
import Iidy.Cfn.Operations.UpdateStack (isNoUpdatesError)
import Iidy.Cfn.StackOperations (PollConfig (..), PollResult (..), defaultPollConfig, isStackNotFoundError, pollForCompletionWith, stackNameFromId)
import Iidy.Cfn.Status (StackStatus (..))

watchStackTests :: [TestTree]
watchStackTests =
    [ testCase "allTerminalStatuses - contains expected statuses" $ do
        assertBool "CreateComplete" (CreateComplete `elem` allTerminalStatuses)
        assertBool "DeleteComplete" (DeleteComplete `elem` allTerminalStatuses)
        assertBool "UpdateComplete" (UpdateComplete `elem` allTerminalStatuses)
        assertBool "RollbackComplete" (RollbackComplete `elem` allTerminalStatuses)
        assertBool "CreateFailed" (CreateFailed `elem` allTerminalStatuses)
    , testCase "allTerminalStatuses - does not contain in-progress" $ do
        assertBool
            "CreateInProgress not terminal"
            (CreateInProgress `notElem` allTerminalStatuses)
        assertBool
            "UpdateInProgress not terminal"
            (UpdateInProgress `notElem` allTerminalStatuses)
    , testCase "stackNameFromId - ARN format" $
        stackNameFromId "arn:aws:cloudformation:us-east-1:123456:stack/my-stack/guid"
            @?= "my-stack"
    , testCase "stackNameFromId - plain name passthrough" $
        stackNameFromId "my-stack" @?= "my-stack"
    , testCase "stackNameFromId - stack ID with slashes" $
        stackNameFromId "prefix/stack-name/suffix"
            @?= "stack-name"
    , testCase "pollForCompletionWith - detects terminal status" $ do
        let events = [mkStackEvt "evt-1" CF.ResourceStatus_CREATE_COMPLETE]
        eventsRef <- newIORef [events]
        let fetchEvents = do
                batches <- readIORef eventsRef
                case batches of
                    (b : rest) -> writeIORef eventsRef rest >> pure b
                    [] -> pure events
        result <-
            pollForCompletionWith
                fetchEvents
                "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                allTerminalStatuses
                (testPollConfig{pcOnNewEvents = const (pure ())})
        result @?= PollSuccess CreateComplete
    , testCase "pollForCompletionWith - polls multiple times until terminal" $ do
        let inProgress = [mkStackEvt "evt-1" CF.ResourceStatus_CREATE_IN_PROGRESS]
            complete =
                [ mkStackEvt "evt-2" CF.ResourceStatus_CREATE_COMPLETE
                , mkStackEvt "evt-1" CF.ResourceStatus_CREATE_IN_PROGRESS
                ]
        eventsRef <- newIORef [inProgress, complete]
        pollCount <- newIORef (0 :: Int)
        let fetchEvents = do
                modifyIORef' pollCount (+ 1)
                batches <- readIORef eventsRef
                case batches of
                    (b : rest) -> writeIORef eventsRef rest >> pure b
                    [] -> pure complete
        result <-
            pollForCompletionWith
                fetchEvents
                "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                allTerminalStatuses
                (testPollConfig{pcOnNewEvents = const (pure ())})
        result @?= PollSuccess CreateComplete
        polls <- readIORef pollCount
        assertBool "should poll at least twice" (polls >= 2)
    , testCase "pollForCompletionWith - fires callback with new events only" $ do
        let inProgress = [mkStackEvt "evt-1" CF.ResourceStatus_CREATE_IN_PROGRESS]
            complete =
                [ mkStackEvt "evt-2" CF.ResourceStatus_CREATE_COMPLETE
                , mkStackEvt "evt-1" CF.ResourceStatus_CREATE_IN_PROGRESS
                ]
        eventsRef <- newIORef [inProgress, complete]
        callbackEvents <- newIORef ([] :: [[Text]])
        let fetchEvents = do
                batches <- readIORef eventsRef
                case batches of
                    (b : rest) -> writeIORef eventsRef rest >> pure b
                    [] -> pure complete
            onNew evts = modifyIORef' callbackEvents (++ [map SE.eventId evts])
        _ <-
            pollForCompletionWith
                fetchEvents
                "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                allTerminalStatuses
                (testPollConfig{pcOnNewEvents = onNew})
        callbacks <- readIORef callbackEvents
        case callbacks of
            (first : second : _) -> do
                assertEqual "first callback has evt-1" ["evt-1"] first
                assertEqual "second callback has evt-2 only" ["evt-2"] second
            _ -> assertFailure ("expected at least 2 callback batches, got " ++ show (length callbacks))
    , testCase "pollForCompletionWith - ignores non-stack resource terminal status" $ do
        let nestedComplete =
                [ mkResourceEvt "evt-1" "MyBucket" "AWS::S3::Bucket" CF.ResourceStatus_CREATE_COMPLETE
                , mkStackEvt "evt-0" CF.ResourceStatus_CREATE_IN_PROGRESS
                ]
            stackComplete =
                [ mkStackEvt "evt-2" CF.ResourceStatus_CREATE_COMPLETE
                , mkResourceEvt "evt-1" "MyBucket" "AWS::S3::Bucket" CF.ResourceStatus_CREATE_COMPLETE
                , mkStackEvt "evt-0" CF.ResourceStatus_CREATE_IN_PROGRESS
                ]
        eventsRef <- newIORef [nestedComplete, stackComplete]
        let fetchEvents = do
                batches <- readIORef eventsRef
                case batches of
                    (b : rest) -> writeIORef eventsRef rest >> pure b
                    [] -> pure stackComplete
        result <-
            pollForCompletionWith
                fetchEvents
                "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                allTerminalStatuses
                (testPollConfig{pcOnNewEvents = const (pure ())})
        result @?= PollSuccess CreateComplete
    , testCase "pollForCompletionWith - detects DELETE_COMPLETE" $ do
        let events = [mkStackEvt "evt-1" CF.ResourceStatus_DELETE_COMPLETE]
        eventsRef <- newIORef [events]
        let fetchEvents = do
                batches <- readIORef eventsRef
                case batches of
                    (b : rest) -> writeIORef eventsRef rest >> pure b
                    [] -> pure events
        result <-
            pollForCompletionWith
                fetchEvents
                "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                allTerminalStatuses
                (testPollConfig{pcOnNewEvents = const (pure ())})
        result @?= PollSuccess DeleteComplete
    , testCase "pollForCompletionWith - detects UPDATE_ROLLBACK_COMPLETE" $ do
        let inProgress = [mkStackEvt "evt-1" CF.ResourceStatus_UPDATE_IN_PROGRESS]
            rollback =
                [ mkStackEvt "evt-2" CF.ResourceStatus_UPDATE_ROLLBACK_COMPLETE
                , mkStackEvt "evt-1" CF.ResourceStatus_UPDATE_IN_PROGRESS
                ]
        eventsRef <- newIORef [inProgress, rollback]
        let fetchEvents = do
                batches <- readIORef eventsRef
                case batches of
                    (b : rest) -> writeIORef eventsRef rest >> pure b
                    [] -> pure rollback
        result <-
            pollForCompletionWith
                fetchEvents
                "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                allTerminalStatuses
                (testPollConfig{pcOnNewEvents = const (pure ())})
        result @?= PollSuccess UpdateRollbackComplete
    , testCase "pollForCompletionWith - returns PollTimeout when overall timeout exceeded" $ do
        -- Set startTime 120 seconds in the past so elapsed > timeout immediately
        let pastTime = addUTCTime (-120) epoch
            events = [mkStackEvt "evt-1" CF.ResourceStatus_CREATE_IN_PROGRESS]
        eventsRef <- newIORef [events]
        let fetchEvents = do
                batches <- readIORef eventsRef
                case batches of
                    (b : rest) -> writeIORef eventsRef rest >> pure b
                    [] -> pure events
        result <-
            pollForCompletionWith
                fetchEvents
                "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                allTerminalStatuses
                ( testPollConfig
                    { pcOnNewEvents = const (pure ())
                    , pcTimeoutSeconds = Just 60
                    , pcStartTime = Just pastTime
                    }
                )
        result @?= PollTimeout
    , testCase "pollForCompletionWith - returns PollInactivityTimeout when idle too long" $ do
        -- Return empty events so lastEventTimeRef stays at startTime (120s ago),
        -- making inactivityElapsed (~120s) > timeout (30s) on the first poll.
        let pastTime = addUTCTime (-120) epoch
        result <-
            pollForCompletionWith
                (pure [])
                "arn:aws:cloudformation:us-east-1:123:stack/demo/guid"
                allTerminalStatuses
                ( testPollConfig
                    { pcOnNewEvents = const (pure ())
                    , pcInactivityTimeoutSecs = Just 30
                    , pcStartTime = Just pastTime
                    }
                )
        result @?= PollInactivityTimeout
    , -- isNoUpdatesError tests
      testGroup
        "isNoUpdatesError"
        [ testCase "returns True for ValidationError with 'No updates' message" $
            isNoUpdatesError (mkAwsServiceError "ValidationError" "No updates are to be performed") @?= True
        , testCase "returns True when message contains 'No updates' substring" $
            isNoUpdatesError (mkAwsServiceError "ValidationError" "Stack: No updates are to be performed.") @?= True
        , testCase "returns False for different error code" $
            isNoUpdatesError (mkAwsServiceError "InternalFailure" "No updates are to be performed") @?= False
        , testCase "returns False for different message" $
            isNoUpdatesError (mkAwsServiceError "ValidationError" "Stack does not exist") @?= False
        , testCase "returns False for non-ServiceError" $
            isNoUpdatesError (mkSerializeError "parse error") @?= False
        ]
    , -- isStackNotFoundError tests
      testGroup
        "isStackNotFoundError"
        [ testCase "returns True for ValidationError with 'does not exist' message" $
            isStackNotFoundError (mkAwsServiceError "ValidationError" "Stack [my-stack] does not exist") @?= True
        , testCase "returns True when message contains 'does not exist' substring" $
            isStackNotFoundError (mkAwsServiceError "ValidationError" "Stack with id my-stack does not exist in region us-east-1") @?= True
        , testCase "returns False for different error code" $
            isStackNotFoundError (mkAwsServiceError "AccessDeniedException" "Stack does not exist") @?= False
        , testCase "returns False for different message" $
            isStackNotFoundError (mkAwsServiceError "ValidationError" "Template format error") @?= False
        , testCase "returns False for ServiceError with no message" $
            isStackNotFoundError (mkAwsServiceErrorNoMsg "ValidationError") @?= False
        , testCase "returns False for non-ServiceError" $
            isStackNotFoundError (mkSerializeError "parse error") @?= False
        ]
    ]
  where
    epoch :: UTCTime
    epoch = UTCTime (fromGregorian 2024 1 1) 0

    testPollConfig :: PollConfig
    testPollConfig = defaultPollConfig{pcIntervalSeconds = 0}

    mkStackEvt :: Text -> CF.ResourceStatus -> SE.StackEvent
    mkStackEvt evtId status =
        (SE.newStackEvent "arn:aws:cloudformation:us-east-1:123:stack/demo/guid" evtId "demo" epoch)
            { SE.logicalResourceId = Just "demo"
            , SE.resourceType = Just "AWS::CloudFormation::Stack"
            , SE.resourceStatus = Just status
            }

    mkResourceEvt :: Text -> Text -> Text -> CF.ResourceStatus -> SE.StackEvent
    mkResourceEvt evtId logicalId resType status =
        (SE.newStackEvent "arn:aws:cloudformation:us-east-1:123:stack/demo/guid" evtId "demo" epoch)
            { SE.logicalResourceId = Just logicalId
            , SE.resourceType = Just resType
            , SE.resourceStatus = Just status
            }

    -- \| Construct an Amazonka ServiceError for testing
    mkAwsServiceError :: Text -> Text -> Amazonka.Error
    mkAwsServiceError code msg =
        Amazonka.ServiceError
            ( AT.ServiceError'
                "CloudFormation"
                status400
                []
                (Amazonka.ErrorCode code)
                (Just (Amazonka.ErrorMessage msg))
                Nothing
            )

    -- \| Construct an Amazonka ServiceError with no message
    mkAwsServiceErrorNoMsg :: Text -> Amazonka.Error
    mkAwsServiceErrorNoMsg code =
        Amazonka.ServiceError
            ( AT.ServiceError'
                "CloudFormation"
                status400
                []
                (Amazonka.ErrorCode code)
                Nothing
                Nothing
            )

    -- \| Construct a non-ServiceError (SerializeError variant) for negative testing
    mkSerializeError :: String -> Amazonka.Error
    mkSerializeError msg =
        Amazonka.SerializeError (AT.SerializeError' "CloudFormation" status400 Nothing msg)
