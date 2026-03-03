module Test.RendererTest (rendererTests) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime(..), addUTCTime, secondsToNominalDiffTime)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Aws.ClientReqToken (DerivedTokenInfo(..), TokenSource(..))
import Iidy.Cfn.Operations.DescribeStack (calculateEventDurations)
import Iidy.Cfn.Status (StackStatus(..))
import Iidy.Output.Color (darkTheme, noColorTheme, IidyTheme(..), colorize, colorizeResourceStatus)
import Iidy.Output.Renderers.Interactive
  ( formatSectionHeading, formatSectionLabel, formatSectionEntry
  , formatLogicalId, styleMuted, renderTimestamp, calcPadding, padRight
  , prettyFormatTags, prettyFormatParameters, formatTokenSource
  , column2Start, minStatusPadding, maxPadding, defaultScreenWidth
  , formatTimingText
  )
import Iidy.Output.Types (StackEventWithTiming(..))
import Test.Shared (mkColoredRenderer, mkPlainRenderer, mkEvent)

rendererTests :: [TestTree]
rendererTests =
  [ testCase "formatSectionHeading - colored output" $ do
      r <- mkColoredRenderer
      let heading = formatSectionHeading r "Stack Definition"
      assertBool "contains ANSI" ("\ESC[" `T.isInfixOf` heading)
      assertBool "contains text" ("Stack Definition" `T.isInfixOf` heading)
      assertBool "ends with colon" (T.isSuffixOf ":" heading)

  , testCase "formatSectionHeading - plain output" $ do
      r <- mkPlainRenderer
      let heading = formatSectionHeading r "Stack Definition"
      assertBool "no ANSI" (not $ "\ESC[" `T.isInfixOf` heading)
      assertEqual "plain heading" "Stack Definition:" heading

  , testCase "formatSectionHeading - strips trailing colon" $ do
      r <- mkPlainRenderer
      let heading = formatSectionHeading r "Events:"
      assertEqual "no double colon" "Events:" heading

  , testCase "formatSectionLabel - muted color" $ do
      r <- mkColoredRenderer
      let lbl = formatSectionLabel r "Status"
      assertBool "contains ANSI" ("\ESC[" `T.isInfixOf` lbl)
      assertBool "contains text" ("Status" `T.isInfixOf` lbl)

  , testCase "formatSectionLabel - plain" $ do
      r <- mkPlainRenderer
      let lbl = formatSectionLabel r "Status"
      assertEqual "plain label" "Status" lbl

  , testCase "formatSectionEntry - colored alignment" $ do
      r <- mkColoredRenderer
      let entry = formatSectionEntry r "Status" "CREATE_COMPLETE"
      assertBool "contains ANSI" ("\ESC[" `T.isInfixOf` entry)
      assertBool "contains value" ("CREATE_COMPLETE" `T.isInfixOf` entry)
      assertBool "starts with space" (T.isPrefixOf " " entry)
      assertBool "ends with newline" (T.isSuffixOf "\n" entry)

  , testCase "formatSectionEntry - plain alignment" $ do
      r <- mkPlainRenderer
      let entry = formatSectionEntry r "Status" "CREATE_COMPLETE"
      assertBool "no ANSI" (not $ "\ESC[" `T.isInfixOf` entry)
      assertBool "contains label" ("Status" `T.isInfixOf` entry)
      assertBool "contains value" ("CREATE_COMPLETE" `T.isInfixOf` entry)

  , testCase "formatLogicalId - colored" $ do
      r <- mkColoredRenderer
      let fid = formatLogicalId r "MyBucket"
      assertBool "contains ANSI" ("\ESC[" `T.isInfixOf` fid)
      assertBool "contains text" ("MyBucket" `T.isInfixOf` fid)

  , testCase "styleMuted - colored" $ do
      r <- mkColoredRenderer
      let muted = styleMuted r "dimmed text"
      assertBool "contains ANSI" ("\ESC[" `T.isInfixOf` muted)

  , testCase "styleMuted - plain" $ do
      r <- mkPlainRenderer
      let muted = styleMuted r "dimmed text"
      assertEqual "no styling" "dimmed text" muted

  , testCase "renderTimestamp - correct format" $ do
      let ts = UTCTime (fromGregorian 2026 2 22) (15 * 3600 + 30 * 60 + 45)
          formatted = renderTimestamp ts
      assertEqual "timestamp format" "Sun Feb 22 2026 15:30:45" formatted

  , testCase "calcPadding - respects min and max" $ do
      assertEqual "empty list uses min" minStatusPadding (calcPadding ([] :: [T.Text]) id)
      let items = [T.replicate 100 "x"]
      assertEqual "long item capped at max" maxPadding (calcPadding items id)
      let shortItems = ["SHORT", "MED"]
      assertEqual "normal items use maxLen" minStatusPadding (calcPadding shortItems id)

  , testCase "padRight - pads short text" $ do
      assertEqual "padded" "hello     " (padRight 10 "hello")
      assertEqual "exact length" "1234567890" (padRight 10 "1234567890")
      assertEqual "longer text unchanged" "12345678901" (padRight 10 "12345678901")

  , testCase "prettyFormatTags - Environment first" $ do
      let tags = Map.fromList [("Version", "1.0"), ("Environment", "production"), ("App", "web")]
      let result = prettyFormatTags tags Nothing
      assertBool "Environment first" (T.isPrefixOf "Environment=production" result)
      assertBool "contains all" ("App=web" `T.isInfixOf` result)

  , testCase "prettyFormatTags - empty" $ do
      assertEqual "empty tags" "" (prettyFormatTags Map.empty Nothing)

  , testCase "prettyFormatParameters - sorted" $ do
      let params = Map.fromList [("Zebra", "z"), ("Alpha", "a"), ("Middle", "m")]
      let result = prettyFormatParameters params
      assertBool "Alpha first" (T.isPrefixOf "Alpha=a" result)
      assertBool "contains all" ("Zebra=z" `T.isInfixOf` result)

  , testCase "prettyFormatParameters - empty" $ do
      assertEqual "empty params" "" (prettyFormatParameters Map.empty)

  , testCase "formatTokenSource - user-provided" $ do
      assertEqual "user" "user-provided" (formatTokenSource UserProvided)

  , testCase "formatTokenSource - auto-generated" $ do
      assertEqual "auto" "auto-generated" (formatTokenSource AutoGenerated)

  , testCase "formatTokenSource - derived" $ do
      let dti = DerivedTokenInfo { dtiFrom = "primary", dtiStep = "create-stack" }
      let result = formatTokenSource (Derived dti)
      assertBool "derived from" ("derived from primary" `T.isInfixOf` result)

  , testCase "formatTimingText - no last event" $ do
      assertEqual "elapsed only"
        "5 seconds elapsed total."
        (formatTimingText 5 Nothing)

  , testCase "formatTimingText - with last event" $ do
      assertEqual "elapsed + since last"
        "10 seconds elapsed total. 3 since last event."
        (formatTimingText 10 (Just 3))

  , testCase "formatTimingText - zero elapsed" $ do
      assertEqual "zero"
        "0 seconds elapsed total."
        (formatTimingText 0 Nothing)

  , testCase "calculateEventDurations - IN_PROGRESS then COMPLETE" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          t5 = addUTCTime (secondsToNominalDiffTime 5) t0
          events =
            [ mkEvent "e1" "MyResource" "AWS::S3::Bucket" CreateInProgress (Just t0)
            , mkEvent "e2" "MyResource" "AWS::S3::Bucket" CreateComplete (Just t5)
            ]
          result = calculateEventDurations events
      assertEqual "IN_PROGRESS has no duration" Nothing (sewDurationSeconds (result !! 0))
      assertEqual "COMPLETE has 5s duration" (Just 5) (sewDurationSeconds (result !! 1))

  , testCase "calculateEventDurations - no matching start" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          events =
            [ mkEvent "e1" "MyResource" "AWS::S3::Bucket" CreateComplete (Just t0)
            ]
          result = calculateEventDurations events
      case result of
        (r:_) -> assertEqual "no start = no duration" Nothing (sewDurationSeconds r)
        []    -> assertFailure "expected at least one result"

  , testCase "calculateEventDurations - FAILED event gets duration" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          t3 = addUTCTime (secondsToNominalDiffTime 3) t0
          events =
            [ mkEvent "e1" "MyResource" "AWS::EC2::Instance" CreateInProgress (Just t0)
            , mkEvent "e2" "MyResource" "AWS::EC2::Instance" CreateFailed (Just t3)
            ]
          result = calculateEventDurations events
      assertEqual "FAILED has 3s duration" (Just 3) (sewDurationSeconds (result !! 1))

  , testCase "calculateEventDurations - multiple resources" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          t2 = addUTCTime (secondsToNominalDiffTime 2) t0
          t4 = addUTCTime (secondsToNominalDiffTime 4) t0
          t7 = addUTCTime (secondsToNominalDiffTime 7) t0
          events =
            [ mkEvent "e1" "Bucket" "AWS::S3::Bucket" CreateInProgress (Just t0)
            , mkEvent "e2" "Instance" "AWS::EC2::Instance" CreateInProgress (Just t2)
            , mkEvent "e3" "Bucket" "AWS::S3::Bucket" CreateComplete (Just t4)
            , mkEvent "e4" "Instance" "AWS::EC2::Instance" CreateComplete (Just t7)
            ]
          result = calculateEventDurations events
      assertEqual "Bucket = 4s" (Just 4) (sewDurationSeconds (result !! 2))
      assertEqual "Instance = 5s" (Just 5) (sewDurationSeconds (result !! 3))

  , testCase "colorize - dark theme applies ANSI" $ do
      let result = colorize darkTheme (thSuccess darkTheme) "OK"
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)
      assertBool "has text" ("OK" `T.isInfixOf` result)

  , testCase "colorize - noColor theme is plain" $ do
      let result = colorize noColorTheme (thSuccess noColorTheme) "OK"
      assertEqual "no color" "OK" result

  , testCase "colorizeResourceStatus - IN_PROGRESS is warning color" $ do
      let result = colorizeResourceStatus darkTheme CreateInProgress
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)
      assertBool "has text" ("CREATE_IN_PROGRESS" `T.isInfixOf` result)

  , testCase "colorizeResourceStatus - COMPLETE is success color" $ do
      let result = colorizeResourceStatus darkTheme CreateComplete
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)

  , testCase "colorizeResourceStatus - FAILED is error color" $ do
      let result = colorizeResourceStatus darkTheme CreateFailed
      assertBool "has ANSI" ("\ESC[" `T.isInfixOf` result)

  , testCase "colorizeResourceStatus - noColor" $ do
      let result = colorizeResourceStatus noColorTheme CreateComplete
      assertEqual "no color" "CREATE_COMPLETE" result

  , testCase "column2Start is 25" $ do
      assertEqual "column2Start" 25 column2Start

  , testCase "defaultScreenWidth is 130" $ do
      assertEqual "defaultScreenWidth" 130 defaultScreenWidth

  ]
