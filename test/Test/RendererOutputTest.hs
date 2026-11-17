module Test.RendererOutputTest (rendererOutputTests) where

import Control.Monad (unless)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import Data.Vector qualified as V
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Cfn.Status (StackStatus (..))
import Iidy.Output.Color (colorizeResourceStatus, darkTheme)
import Iidy.Output.Renderers.Interactive (
    formatLogicalId,
    formatSectionEntry,
    formatSectionHeading,
    prettyFormatParameters,
    prettyFormatTags,
    renderTimestamp,
 )
import Iidy.Output.Renderers.Json (
    defToValue,
    defaultJsonOptions,
    encodeValue,
    eventWithTimingToValue,
    stackListEntryToValue,
    stackListToValue,
 )
import Iidy.Output.Types
import Test.Shared

rendererOutputTests :: [TestTree]
rendererOutputTests =
    [ testCase "formatSectionEntry renders stack definition fields" $ do
        r <- mkPlainRenderer
        let nameEntry = formatSectionEntry r "Name" "my-stack"
            statusEntry = formatSectionEntry r "Status" "CREATE_COMPLETE"
            regionEntry = formatSectionEntry r "Region" "us-east-1"
        assertBool "name entry has stack name" ("my-stack" `T.isInfixOf` nameEntry)
        assertBool "status entry has status" ("CREATE_COMPLETE" `T.isInfixOf` statusEntry)
        assertBool "region entry has region" ("us-east-1" `T.isInfixOf` regionEntry)
    , testCase "formatSectionEntry colored has ANSI, plain does not" $ do
        colored <- mkColoredRenderer
        plain <- mkPlainRenderer
        let coloredEntry = formatSectionEntry colored "Status" "CREATE_COMPLETE"
            plainEntry = formatSectionEntry plain "Status" "CREATE_COMPLETE"
        assertBool "colored has ANSI" ("\ESC[" `T.isInfixOf` coloredEntry)
        assertBool "plain no ANSI" (not $ "\ESC[" `T.isInfixOf` plainEntry)
        assertBool "both have value" ("CREATE_COMPLETE" `T.isInfixOf` coloredEntry && "CREATE_COMPLETE" `T.isInfixOf` plainEntry)
    , testCase "formatSectionHeading renders event titles" $ do
        r <- mkPlainRenderer
        let heading = formatSectionHeading r "Recent Events"
        assertEqual "plain heading" "Recent Events:" heading
    , testCase "formatLogicalId renders resource names" $ do
        r <- mkPlainRenderer
        let fid = formatLogicalId r "MyBucket"
        assertEqual "plain id" "MyBucket" fid
    , testCase "formatLogicalId colored wraps with ANSI" $ do
        r <- mkColoredRenderer
        let fid = formatLogicalId r "WebServer"
        assertBool "has ANSI" ("\ESC[" `T.isInfixOf` fid)
        assertBool "has name" ("WebServer" `T.isInfixOf` fid)
    , testCase "colorizeResourceStatus maps status families correctly" $ do
        let inProgressResult = colorizeResourceStatus darkTheme CreateInProgress
        assertBool "in_progress colored" ("\ESC[" `T.isInfixOf` inProgressResult)
        let completeResult = colorizeResourceStatus darkTheme UpdateComplete
        assertBool "complete colored" ("\ESC[" `T.isInfixOf` completeResult)
        let failedResult = colorizeResourceStatus darkTheme DeleteFailed
        assertBool "failed colored" ("\ESC[" `T.isInfixOf` failedResult)
        let rollbackResult = colorizeResourceStatus darkTheme RollbackInProgress
        assertBool "rollback colored" ("\ESC[" `T.isInfixOf` rollbackResult)
    , testCase "renderTimestamp produces expected format" $ do
        let ts = UTCTime (fromGregorian 2026 1 15) (10 * 3600 + 5 * 60 + 30)
            formatted = renderTimestamp ts
        assertEqual "timestamp" "Thu Jan 15 2026 10:05:30" formatted
    , testCase "prettyFormatTags with environment and env" $ do
        let tags = Map.fromList [("Environment", "staging"), ("Name", "my-stack")]
            result = prettyFormatTags tags (Just 100)
        assertBool "Environment first" (T.isPrefixOf "Environment=staging" result)
        assertBool "contains Name" ("Name=my-stack" `T.isInfixOf` result)
    , testCase "prettyFormatParameters with multiple params" $ do
        let params = Map.fromList [("InstanceType", "t3.micro"), ("Env", "prod"), ("VpcId", "vpc-123")]
            result = prettyFormatParameters params
        assertBool "sorted alphabetically" (T.isPrefixOf "Env=prod" result)
        assertBool "contains all" ("InstanceType=t3.micro" `T.isInfixOf` result && "VpcId=vpc-123" `T.isInfixOf` result)
    , testCase "JSON value for stack list entry query mode" $ do
        let entries = [stackListEntryToValue testStackListEntry]
            val = Aeson.toJSON entries
            encoded = encodeValue defaultJsonOptions val
            parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
        case parsed of
            Nothing -> assertFailure "Failed to parse JSON array"
            Just (Array arr) -> assertEqual "one entry" 1 (V.length arr)
            Just other -> assertFailure ("Expected array, got: " <> show other)
    , testCase "JSON stack list non-query mode has wrapper" $ do
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
        assertBool "has stacks" (isJust (jsonLookup "stacks" val))
        assertBool "has filters" (isJust (jsonLookup "filters_applied" val))
        assertBool "has columns" (isJust (jsonLookup "columns" val))
    , testCase "JSON stack definition envelope structure" $ do
        let envelope =
                Aeson.object
                    [ "type" Aeson..= ("stack_definition" :: Text)
                    , "data"
                        Aeson..= Aeson.object
                            [ "stack_definition" Aeson..= defToValue testStackDef
                            , "show_times" Aeson..= True
                            ]
                    ]
            encoded = encodeValue defaultJsonOptions envelope
            parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
        case parsed of
            Nothing -> assertFailure "Failed to parse JSON"
            Just v -> do
                assertEqual "type" (Just (String "stack_definition")) (jsonLookup "type" v)
                assertBool "has data" (isJust (jsonLookup "data" v))
    , testCase "JSON new stack events is array of event objects" $ do
        let events = Aeson.toJSON [eventWithTimingToValue testEventWithTiming]
            encoded = encodeValue defaultJsonOptions events
            parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
        case parsed of
            Nothing -> assertFailure "Failed to parse JSON"
            Just (Array arr) -> do
                assertEqual "one event" 1 (V.length arr)
                case arr V.!? 0 of
                    Just (Object _) -> pure ()
                    Just other -> assertFailure ("Expected object in array, got: " <> show other)
                    Nothing -> assertFailure "expected at least one element"
            Just other -> assertFailure ("Expected array, got: " <> show other)
    , untrustedTextTests
    ]

------------------------------------------------------------------------
-- Control characters in untrusted text (card C18)
------------------------------------------------------------------------

-- | Untrusted text: a terminal erase-line sequence and a bare carriage return.
payload :: Text
payload = "X\ESC[2Ky\rZ"

-- | How 'payload' must appear once escaped.
payloadVisible :: Text
payloadVisible = "X\\u001b[2Ky\\u000dZ"

failedEvent :: StackEventWithTiming
failedEvent =
    testEventWithTiming
        { sewEvent =
            testStackEvent
                { seResourceStatus = CreateFailed
                , seResourceStatusReason = Just payload
                }
        }

-- | One sink per family; each carries 'payload' in the named place.
untrustedSinks :: [(String, OutputData)]
untrustedSinks =
    [ ("template diff", OdTemplateDiff testTemplateDiff{tdDiffOutput = "+ " <> payload <> "\n"})
    , ("event status reason", OdStackEvents testStackEventsDisplay{sedEvents = [failedEvent]})
    , ("event section title", OdStackEvents testStackEventsDisplay{sedTitle = payload})
    , ("stack tag value", OdStackDefinition testStackDef{sdTags = Map.fromList [("Owner", payload)]} False)
    , ("stack tag key", OdStackDefinition testStackDef{sdTags = Map.fromList [(payload, "v")]} False)
    , ("stack parameter value", OdStackDefinition testStackDef{sdParameters = Map.fromList [("P", payload)]} False)
    , ("stack name", OdStackDefinition testStackDef{sdName = payload} False)
    , ("stack description", OdStackDefinition testStackDef{sdDescription = Just payload} False)
    , ("stack output value", OdStackContents (withOutput testStackContents "BucketName" payload))
    , ("stack output key", OdStackContents (withOutput testStackContents payload "v"))
    , ("error message", OdError testErrorInfo{eiMessage = payload})
    , ("error details", OdError testErrorInfo{eiErrorDetails = ErrorGeneric (Just payload)})
    , ("error suggestion", OdError testErrorInfo{eiSuggestions = [payload]})
    , ("status update", OdStatusUpdate testStatusUpdate{suMessage = payload})
    , ("command result message", OdCommandResult testCommandResult{crMessage = Just payload})
    , ("stack list name", OdStackList testStackListDisplay{sldStacks = [testStackListEntry{sleStackName = payload}]})
    , ("stack list tag", OdStackList testStackListDisplay{sldStacks = [testStackListEntry{sleTags = Map.fromList [("k", payload)]}]})
    , ("changeset next step", OdChangeSetResult testChangeSetResult{csrNextSteps = [payload]})
    , ("drift actual value", OdStackDrift (withActual testStackDrift payload))
    , ("template stderr line", OdStackTemplate testStackTemplate{stStderrLines = [payload]})
    , ("confirmation message", OdConfirmationPrompt testConfirmationRequest{cfrMessage = payload})
    ]
  where
    withOutput c k v =
        c{scOutputs = [StackOutputInfo{soiOutputKey = k, soiOutputValue = v, soiDescription = Nothing, soiExportName = Nothing}]}
    withActual d v =
        d{sdrDriftedResources = [dr{drPropertyDifferences = [pd{pdActualValue = Just v} | pd <- drPropertyDifferences dr]} | dr <- sdrDriftedResources d]}

untrustedTextTests :: TestTree
untrustedTextTests =
    testGroup
        "untrusted text is escaped"
        ( concatMap sinkCases untrustedSinks
            <> [ testCase "columns are aligned on the visible escaped text" $ do
                    let ev rtype = testEventWithTiming{sewEvent = testStackEvent{seResourceType = rtype}}
                        display = testStackEventsDisplay{sedEvents = [ev payload, ev "AWS::S3::Bucket"]}
                    out <- renderCaptured False [OdStackEvents display]
                    -- the escaped payload is 18 characters wide, so the other type is padded to 18
                    assertBool ("aligned in: " <> show out) ("AWS::S3::Bucket    MyBucket" `T.isInfixOf` out)
               , testCase "OdRawOutput passes through unchanged" $ do
                    out <- renderCaptured True [OdRawOutput rawWithControls]
                    assertEqual "raw bytes" rawWithControls out
               , testCase "OdStackTemplate body passes through unchanged" $ do
                    let tmpl = testStackTemplate{stStderrLines = [], stTemplateBody = rawWithControls}
                    out <- renderCaptured True [OdStackTemplate tmpl]
                    assertEqual "template body" (rawWithControls <> "\n") out
               ]
        )
  where
    rawWithControls = "a: \ESC[2K\rb\x202e\&c\n"
    sinkCases (name, od) =
        [ testCase (name <> " (colored)") $ do
            out <- renderCaptured True [od]
            assertEscaped out
            -- these two sinks are written without the renderer's colour
            unless (name `elem` ["template stderr line", "confirmation message"]) $
                assertBool "renderer's own colour codes remain" ("\ESC[" `T.isInfixOf` out)
        , testCase (name <> " (plain)") $ do
            out <- renderCaptured False [od]
            assertEscaped out
            assertBool "no raw ESC at all when colour is off" (not ("\ESC" `T.isInfixOf` out))
        ]
    assertEscaped out = do
        assertBool ("escaped form present in: " <> show out) (payloadVisible `T.isInfixOf` out)
        assertBool "no raw ESC[2K from the data" (not ("\ESC[2K" `T.isInfixOf` out))
        assertBool "no raw carriage return" (not ("\r" `T.isInfixOf` out))
