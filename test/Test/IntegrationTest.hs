module Test.IntegrationTest (integrationTests) where

import Control.Exception (try, SomeException)
import Control.Monad (forM, when)
import Data.List (nub)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Output.Renderers.Interactive
  ( plainInteractiveOptions, defaultInteractiveOptions
  , newInteractiveRenderer
  , renderOutputData
  )
import Iidy.Output.Renderers.Json
  ( defaultJsonOptions
  , newJsonRenderer
  , renderOutputDataJson
  )
import Iidy.Output.Types (OutputData(..))
import Test.Shared

integrationTests :: [TestTree]
integrationTests =
  [ testGroup "InteractiveRenderer" interactiveRendererIntegrationTests
  , testGroup "JsonRenderer" jsonRendererIntegrationTests
  , testGroup "OutputSequences" outputSequenceTests
  ]

interactiveRendererIntegrationTests :: [TestTree]
interactiveRendererIntegrationTests =
  [ testCase "renderOutputData handles all OutputData variants without crashing" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      results <- forM allTestOutputData $ \od -> do
        result <- try (renderOutputData r od) :: IO (Either SomeException ())
        case result of
          Left ex -> pure (Just (show od, ex))
          Right () -> pure Nothing
      let failures = [f | Just f <- results]
      when (not (null failures)) $
        assertFailure $ "Renderer crashed on variants: " <>
          unlines [tag <> ": " <> show ex | (tag, ex) <- failures]

  , testCase "renderOutputData colored handles all OutputData variants" $ do
      r <- newInteractiveRenderer defaultInteractiveOptions
      results <- forM allTestOutputData $ \od -> do
        result <- try (renderOutputData r od) :: IO (Either SomeException ())
        case result of
          Left ex -> pure (Just (show od, ex))
          Right () -> pure Nothing
      let failures = [f | Just f <- results]
      when (not (null failures)) $
        assertFailure $ "Colored renderer crashed on: " <>
          unlines [tag <> ": " <> show ex | (tag, ex) <- failures]

  , testCase "renderOutputData processes create-stack sequence in order" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
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
      mapM_ (renderOutputData r) createSeq

  , testCase "renderOutputData processes describe-stack sequence in order" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      let describeSeq =
            [ OdCommandMetadata testCommandMetadata
            , OdStackDefinition testStackDef True
            , OdStackEvents testStackEventsDisplay
            , OdStackContents testStackContents
            , OdFinalCommandSummary testFinalCommandSummary
            ]
      mapM_ (renderOutputData r) describeSeq

  , testCase "renderOutputData processes delete-stack sequence in order" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      let deleteSeq =
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
      mapM_ (renderOutputData r) deleteSeq

  , testCase "renderOutputData processes changeset sequence in order" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      let changeSetSeq =
            [ OdCommandMetadata testCommandMetadata
            , OdStackDefinition testStackDef True
            , OdChangeSetResult testChangeSetResult
            , OdFinalCommandSummary testFinalCommandSummary
            ]
      mapM_ (renderOutputData r) changeSetSeq

  , testCase "renderOutputData processes drift sequence in order" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      let driftSeq =
            [ OdCommandMetadata testCommandMetadata
            , OdStackDefinition testStackDef False
            , OdPollingStarted "Detecting drift..."
            , OdStackDrift testStackDrift
            , OdFinalCommandSummary testFinalCommandSummary
            ]
      mapM_ (renderOutputData r) driftSeq

  , testCase "renderOutputData processes stack-absent error" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      let absentSeq =
            [ OdCommandMetadata testCommandMetadata
            , OdStackAbsentInfo testAbsentInfo
            ]
      mapM_ (renderOutputData r) absentSeq

  , testCase "renderOutputData processes lint+approval sequence" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      let approvalSeq =
            [ OdTemplateValidation testTemplateValidation
            , OdApprovalRequestResult testApprovalRequestResult
            , OdApprovalStatus testApprovalStatus
            , OdTemplateDiff testTemplateDiff
            , OdApprovalResult testApprovalResult
            ]
      mapM_ (renderOutputData r) approvalSeq

  , testCase "renderOutputData handles empty events list" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      renderOutputData r (OdNewStackEvents [])

  , testCase "renderOutputData handles stack list" $ do
      r <- newInteractiveRenderer plainInteractiveOptions
      renderOutputData r (OdStackList testStackListDisplay)
  ]

jsonRendererIntegrationTests :: [TestTree]
jsonRendererIntegrationTests =
  [ testCase "renderOutputDataJson handles all OutputData variants without crashing" $ do
      let jr = newJsonRenderer defaultJsonOptions
      results <- forM allTestOutputData $ \od -> do
        result <- try (renderOutputDataJson jr od) :: IO (Either SomeException ())
        case result of
          Left ex -> pure (Just (show od, ex))
          Right () -> pure Nothing
      let failures = [f | Just f <- results]
      when (not (null failures)) $
        assertFailure $ "JSON renderer crashed on variants: " <>
          unlines [tag <> ": " <> show ex | (tag, ex) <- failures]

  , testCase "renderOutputDataJson handles create-stack sequence" $ do
      let jr = newJsonRenderer defaultJsonOptions
      let jsonCreateSeq =
            [ OdCommandMetadata testCommandMetadata
            , OdStackChangeDetails testStackChangeDetails
            , OdStackDefinition testStackDef True
            , OdPollingStarted "Loading..."
            , OdNewStackEvents [testEventWithTiming]
            , OdOperationComplete testOperationComplete
            , OdStackContents testStackContents
            , OdFinalCommandSummary testFinalCommandSummary
            ]
      mapM_ (renderOutputDataJson jr) jsonCreateSeq
  ]

outputSequenceTests :: [TestTree]
outputSequenceTests =
  [ testCase "allTestOutputData covers all 27 OutputData variant types" $ do
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
