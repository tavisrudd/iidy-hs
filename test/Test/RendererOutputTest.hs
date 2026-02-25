module Test.RendererOutputTest (rendererOutputTests) where

import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime(..))
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Output.Color (darkTheme, colorizeResourceStatus)
import Iidy.Output.Renderers.Interactive
  ( formatSectionHeading, formatSectionEntry
  , formatLogicalId
  , renderTimestamp
  , prettyFormatTags, prettyFormatParameters
  )
import Iidy.Output.Renderers.Json
  ( defaultJsonOptions, defToValue, eventWithTimingToValue
  , stackListEntryToValue, stackListToValue, encodeValue
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
      let inProgressResult = colorizeResourceStatus darkTheme "CREATE_IN_PROGRESS"
      assertBool "in_progress colored" ("\ESC[" `T.isInfixOf` inProgressResult)
      let completeResult = colorizeResourceStatus darkTheme "UPDATE_COMPLETE"
      assertBool "complete colored" ("\ESC[" `T.isInfixOf` completeResult)
      let failedResult = colorizeResourceStatus darkTheme "DELETE_FAILED"
      assertBool "failed colored" ("\ESC[" `T.isInfixOf` failedResult)
      let rollbackResult = colorizeResourceStatus darkTheme "ROLLBACK_IN_PROGRESS"
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
      let display = StackListDisplay
            { sldStacks = [testStackListEntry]
            , sldShowTags = True
            , sldFiltersApplied = ["status:CREATE_COMPLETE"]
            , sldColumns = [ColName, ColStatus, ColTags]
            , sldQueryMode = False
            }
          val = stackListToValue display
      assertEqual "show_tags" (Just (Aeson.Bool True)) (jsonLookup "show_tags" val)
      assertBool "has stacks" (jsonLookup "stacks" val /= Nothing)
      assertBool "has filters" (jsonLookup "filters_applied" val /= Nothing)
      assertBool "has columns" (jsonLookup "columns" val /= Nothing)

  , testCase "JSON stack definition envelope structure" $ do
      let envelope = Aeson.object
            [ "type" Aeson..= ("stack_definition" :: Text)
            , "data" Aeson..= Aeson.object
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
          assertBool "has data" (jsonLookup "data" v /= Nothing)

  , testCase "JSON new stack events is array of event objects" $ do
      let events = Aeson.toJSON (map eventWithTimingToValue [testEventWithTiming])
          encoded = encodeValue defaultJsonOptions events
          parsed = Aeson.decode (BL.fromStrict (TE.encodeUtf8 encoded)) :: Maybe Value
      case parsed of
        Nothing -> assertFailure "Failed to parse JSON"
        Just (Array arr) -> do
          assertEqual "one event" 1 (V.length arr)
          case V.head arr of
            Object _ -> pure ()
            other -> assertFailure ("Expected object in array, got: " <> show other)
        Just other -> assertFailure ("Expected array, got: " <> show other)
  ]
