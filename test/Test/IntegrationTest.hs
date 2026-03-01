module Test.IntegrationTest (integrationTests) where

import Control.Exception (try, SomeException)
import Control.Monad (forM, when)
import Data.List (nub)
import System.IO (IOMode(..), withFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Output.Renderers.Interactive
  ( InteractiveRenderer, InteractiveOptions
  , plainInteractiveOptions, defaultInteractiveOptions
  , newInteractiveRendererWithHandles
  , renderOutputData
  )
import Iidy.Output.Renderers.Json
  ( JsonRenderer, JsonOptions
  , defaultJsonOptions
  , newJsonRendererWithHandles
  , renderOutputDataJson
  )
import Iidy.Output.Types (OutputData(..))
import Test.Shared

-- | Create an InteractiveRenderer that writes to /dev/null
withSilentInteractiveRenderer :: InteractiveOptions -> (InteractiveRenderer -> IO a) -> IO a
withSilentInteractiveRenderer opts action =
  withFile "/dev/null" WriteMode $ \devNull ->
    newInteractiveRendererWithHandles devNull devNull opts >>= action

-- | Create a JsonRenderer that writes to /dev/null
withSilentJsonRenderer :: JsonOptions -> (JsonRenderer -> IO a) -> IO a
withSilentJsonRenderer opts action =
  withFile "/dev/null" WriteMode $ \devNull ->
    action (newJsonRendererWithHandles devNull devNull opts)

integrationTests :: [TestTree]
integrationTests =
  [ testGroup "InteractiveRenderer" interactiveRendererIntegrationTests
  , testGroup "JsonRenderer" jsonRendererIntegrationTests
  , testGroup "OutputSequences" outputSequenceTests
  ]

interactiveRendererIntegrationTests :: [TestTree]
interactiveRendererIntegrationTests =
  [ testCase "renderOutputData handles all OutputData variants without crashing" $
      withSilentInteractiveRenderer plainInteractiveOptions $ \r -> do
        results <- forM allTestOutputData $ \od -> do
          result <- try (renderOutputData r od) :: IO (Either SomeException ())
          case result of
            Left ex -> pure (Just (show od, ex))
            Right () -> pure Nothing
        let failures = [f | Just f <- results]
        when (not (null failures)) $
          assertFailure $ "Renderer crashed on variants: " <>
            unlines [tag <> ": " <> show ex | (tag, ex) <- failures]

  , testCase "renderOutputData colored handles all OutputData variants" $
      withSilentInteractiveRenderer defaultInteractiveOptions $ \r -> do
        results <- forM allTestOutputData $ \od -> do
          result <- try (renderOutputData r od) :: IO (Either SomeException ())
          case result of
            Left ex -> pure (Just (show od, ex))
            Right () -> pure Nothing
        let failures = [f | Just f <- results]
        when (not (null failures)) $
          assertFailure $ "Colored renderer crashed on: " <>
            unlines [tag <> ": " <> show ex | (tag, ex) <- failures]

  , testCase "renderOutputData processes create-stack sequence in order" $
      withSilentInteractiveRenderer plainInteractiveOptions $ \r ->
        mapM_ (renderOutputData r)
          [ OdCommandMetadata testCommandMetadata
          , OdStackChangeDetails testStackChangeDetails
          , OdStackDefinition testStackDef True
          , OdPollingStarted "Loading live events..."
          , OdNewStackEvents [testEventWithTiming]
          , OdOperationComplete testOperationComplete
          , OdStackContents testStackContents
          , OdFinalCommandSummary testFinalCommandSummary
          ]

  , testCase "renderOutputData processes describe-stack sequence in order" $
      withSilentInteractiveRenderer plainInteractiveOptions $ \r ->
        mapM_ (renderOutputData r)
          [ OdCommandMetadata testCommandMetadata
          , OdStackDefinition testStackDef True
          , OdStackEvents testStackEventsDisplay
          , OdStackContents testStackContents
          , OdFinalCommandSummary testFinalCommandSummary
          ]

  , testCase "renderOutputData processes delete-stack sequence in order" $
      withSilentInteractiveRenderer plainInteractiveOptions $ \r ->
        mapM_ (renderOutputData r)
          [ OdCommandMetadata testCommandMetadata
          , OdStackDefinition testStackDef True
          , OdStackEvents testStackEventsDisplay
          , OdStackContents testStackContents
          , OdConfirmationPrompt testConfirmationRequest
          , OdPollingStarted "Waiting for stack deletion..."
          , OdNewStackEvents [testEventWithTiming]
          , OdOperationComplete testOperationComplete
          , OdFinalCommandSummary testFinalCommandSummary
          ]

  , testCase "renderOutputData processes changeset sequence in order" $
      withSilentInteractiveRenderer plainInteractiveOptions $ \r ->
        mapM_ (renderOutputData r)
          [ OdCommandMetadata testCommandMetadata
          , OdStackDefinition testStackDef True
          , OdChangeSetResult testChangeSetResult
          , OdFinalCommandSummary testFinalCommandSummary
          ]

  , testCase "renderOutputData processes drift sequence in order" $
      withSilentInteractiveRenderer plainInteractiveOptions $ \r ->
        mapM_ (renderOutputData r)
          [ OdCommandMetadata testCommandMetadata
          , OdStackDefinition testStackDef False
          , OdPollingStarted "Detecting drift..."
          , OdStackDrift testStackDrift
          , OdFinalCommandSummary testFinalCommandSummary
          ]

  , testCase "renderOutputData processes stack-absent error" $
      withSilentInteractiveRenderer plainInteractiveOptions $ \r ->
        mapM_ (renderOutputData r)
          [ OdCommandMetadata testCommandMetadata
          , OdStackAbsentInfo testAbsentInfo
          ]

  , testCase "renderOutputData processes lint+approval sequence" $
      withSilentInteractiveRenderer plainInteractiveOptions $ \r ->
        mapM_ (renderOutputData r)
          [ OdTemplateValidation testTemplateValidation
          , OdApprovalRequestResult testApprovalRequestResult
          , OdApprovalStatus testApprovalStatus
          , OdTemplateDiff testTemplateDiff
          , OdApprovalResult testApprovalResult
          ]

  , testCase "renderOutputData handles empty events list" $
      withSilentInteractiveRenderer plainInteractiveOptions $ \r ->
        renderOutputData r (OdNewStackEvents [])

  , testCase "renderOutputData handles stack list" $
      withSilentInteractiveRenderer plainInteractiveOptions $ \r ->
        renderOutputData r (OdStackList testStackListDisplay)
  ]

jsonRendererIntegrationTests :: [TestTree]
jsonRendererIntegrationTests =
  [ testCase "renderOutputDataJson handles all OutputData variants without crashing" $
      withSilentJsonRenderer defaultJsonOptions $ \jr -> do
        results <- forM allTestOutputData $ \od -> do
          result <- try (renderOutputDataJson jr od) :: IO (Either SomeException ())
          case result of
            Left ex -> pure (Just (show od, ex))
            Right () -> pure Nothing
        let failures = [f | Just f <- results]
        when (not (null failures)) $
          assertFailure $ "JSON renderer crashed on variants: " <>
            unlines [tag <> ": " <> show ex | (tag, ex) <- failures]

  , testCase "renderOutputDataJson handles create-stack sequence" $
      withSilentJsonRenderer defaultJsonOptions $ \jr ->
        mapM_ (renderOutputDataJson jr)
          [ OdCommandMetadata testCommandMetadata
          , OdStackChangeDetails testStackChangeDetails
          , OdStackDefinition testStackDef True
          , OdPollingStarted "Loading..."
          , OdNewStackEvents [testEventWithTiming]
          , OdOperationComplete testOperationComplete
          , OdStackContents testStackContents
          , OdFinalCommandSummary testFinalCommandSummary
          ]
  ]

outputSequenceTests :: [TestTree]
outputSequenceTests =
  [ testCase "allTestOutputData covers all 26 OutputData variant types" $ do
      let uniqueTypes = nub (map odConstructorName allTestOutputData)
      assertEqual "unique OutputData constructors covered"
        26
        (length uniqueTypes)

  , testCase "create-stack sequence has correct order" $ do
      let createSeq =
            [ OdCommandMetadata testCommandMetadata
            , OdStackChangeDetails testStackChangeDetails
            , OdStackDefinition testStackDef True
            , OdPollingStarted "Loading live events..."
            , OdNewStackEvents [testEventWithTiming]
            , OdOperationComplete testOperationComplete
            , OdStackContents testStackContents
            , OdFinalCommandSummary testFinalCommandSummary
            ]
          names = map odConstructorName createSeq
      assertEqual "sequence order"
        ["CommandMetadata", "StackChangeDetails", "StackDefinition"
        ,"PollingStarted", "NewStackEvents", "OperationComplete"
        ,"StackContents", "FinalCommandSummary"]
        names

  , testCase "describe-stack sequence has correct order" $ do
      let describeSeq =
            [ OdCommandMetadata testCommandMetadata
            , OdStackDefinition testStackDef True
            , OdStackEvents testStackEventsDisplay
            , OdStackContents testStackContents
            , OdFinalCommandSummary testFinalCommandSummary
            ]
          names = map odConstructorName describeSeq
      assertEqual "sequence order"
        ["CommandMetadata", "StackDefinition", "StackEvents"
        ,"StackContents", "FinalCommandSummary"]
        names

  , testCase "delete-stack sequence has correct order" $ do
      let deleteSeq =
            [ OdCommandMetadata testCommandMetadata
            , OdStackDefinition testStackDef True
            , OdStackEvents testStackEventsDisplay
            , OdStackContents testStackContents
            , OdConfirmationPrompt testConfirmationRequest
            , OdPollingStarted "Waiting..."
            , OdNewStackEvents [testEventWithTiming]
            , OdOperationComplete testOperationComplete
            , OdFinalCommandSummary testFinalCommandSummary
            ]
          names = map odConstructorName deleteSeq
      assertEqual "sequence order"
        ["CommandMetadata", "StackDefinition", "StackEvents"
        ,"StackContents", "ConfirmationPrompt", "PollingStarted"
        ,"NewStackEvents", "OperationComplete", "FinalCommandSummary"]
        names
  ]
