{-# LANGUAGE DisambiguateRecordFields #-}
module Test.Phase14FixTest (phase14FixTests) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Amazonka
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime(..), addUTCTime, secondsToNominalDiffTime)
import Network.HTTP.Types.Status (status400)
import qualified Amazonka.CloudFormation.Types.StackEvent as SE
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Aws.Config (sourceDisplayName, credentialDisplayName)
import Iidy.Aws.CredentialSource
  ( AwsSettings(..)
  , CredentialSource(..), CredentialSourceStack(..)
  , ProfileInfo(..), ProfileSource(..)
  )
import Iidy.Cfn.CommandMetadata (buildCliArguments)
import Iidy.Cfn.Operations.DescribeStack (calculateEventDurations, convertEventWithDuration)
import Iidy.Cfn.Operations.UpdateStack (isNoUpdatesError)
import Iidy.Cfn.StackArgsLoader (getStrMapValidated)
import Iidy.Output.Types (StackEventWithTiming(..))
import Test.Shared (mkEvent)

phase14FixTests :: [TestTree]
phase14FixTests =
  -- 1. buildCliArguments: only includes explicit CLI flags
  [ testCase "buildCliArguments - no flags = empty map" $ do
      let settings = AwsSettings Nothing Nothing Nothing
      buildCliArguments settings Nothing @?= Map.empty

  , testCase "buildCliArguments - all flags present" $ do
      let settings = AwsSettings (Just "prod") (Just "eu-west-1") (Just "arn:aws:iam::role/x")
      let result = buildCliArguments settings (Just "my-stack")
      Map.lookup "profile" result @?= Just "prod"
      Map.lookup "region" result @?= Just "eu-west-1"
      Map.lookup "stack-name" result @?= Just "my-stack"
      Map.lookup "assume-role-arn" result @?= Just "arn:aws:iam::role/x"

  , testCase "buildCliArguments - no CLI stack name excludes stack-name" $ do
      let settings = AwsSettings (Just "prod") Nothing Nothing
      let result = buildCliArguments settings Nothing
      Map.lookup "stack-name" result @?= Nothing
      Map.lookup "profile" result @?= Just "prod"

  -- 2. getStrMapValidated: rejects non-string values
  , testCase "getStrMapValidated - valid string map" $ do
      let obj = KM.fromList
            [ (AesonKey.fromText "Tags", Object $ KM.fromList
                [ (AesonKey.fromText "Env", String "prod")
                , (AesonKey.fromText "Team", String "platform")
                ])
            ]
      case getStrMapValidated obj "Tags" of
        Right (Just m) -> do
          Map.lookup "Env" m @?= Just "prod"
          Map.lookup "Team" m @?= Just "platform"
        Right Nothing -> assertFailure "expected Just, got Nothing"
        Left e -> assertFailure ("unexpected error: " <> T.unpack e)

  , testCase "getStrMapValidated - rejects integer value" $ do
      let obj = KM.fromList
            [ (AesonKey.fromText "Tags", Object $ KM.fromList
                [ (AesonKey.fromText "Count", Number 42)
                ])
            ]
      case getStrMapValidated obj "Tags" of
        Left e -> assertBool "mentions expected a string" ("expected a string" `T.isInfixOf` e)
        Right _ -> assertFailure "should reject non-string value"

  , testCase "getStrMapValidated - rejects boolean value" $ do
      let obj = KM.fromList
            [ (AesonKey.fromText "Tags", Object $ KM.fromList
                [ (AesonKey.fromText "Enabled", Bool True)
                ])
            ]
      case getStrMapValidated obj "Tags" of
        Left e -> assertBool "mentions expected a string" ("expected a string" `T.isInfixOf` e)
        Right _ -> assertFailure "should reject boolean value"

  , testCase "getStrMapValidated - missing key = Nothing" $ do
      let obj = KM.fromList []
      getStrMapValidated obj "Tags" @?= Right Nothing

  , testCase "getStrMapValidated - non-object type = error" $ do
      let obj = KM.fromList
            [ (AesonKey.fromText "Tags", String "not-a-map")
            ]
      case getStrMapValidated obj "Tags" of
        Left e -> assertBool "mentions expected a mapping" ("expected a mapping" `T.isInfixOf` e)
        Right _ -> assertFailure "should reject non-object type"

  -- 3. Credential display text
  , testCase "sourceDisplayName - static env vars" $
      sourceDisplayName EnvironmentVariablesStatic
        @?= "environment variables (AWS_ACCESS_KEY_ID)"

  , testCase "sourceDisplayName - temporary env vars" $
      sourceDisplayName EnvironmentVariablesTemporary
        @?= "environment variables (AWS_ACCESS_KEY_ID + AWS_SESSION_TOKEN)"

  , testCase "sourceDisplayName - profile from CLI" $ do
      let pinfo = ProfileInfo "production" ProfileCliFlag Nothing
      sourceDisplayName (ProfileCredential pinfo)
        @?= "profile 'production' (CLI flag)"

  , testCase "sourceDisplayName - profile from stack-args" $ do
      let pinfo = ProfileInfo "dev" ProfileStackArgs Nothing
      sourceDisplayName (ProfileCredential pinfo)
        @?= "profile 'dev' (stack-args)"

  , testCase "credentialDisplayName - single source" $ do
      let stack = CredentialSourceStack [EnvironmentVariablesStatic]
      credentialDisplayName stack
        @?= "environment variables (AWS_ACCESS_KEY_ID)"

  , testCase "credentialDisplayName - with override" $ do
      let stack = CredentialSourceStack
            [ EnvironmentVariablesTemporary
            , EnvironmentVariablesStatic
            ]
      let result = credentialDisplayName stack
      assertBool "shows overriding" ("overriding" `T.isInfixOf` result)
      assertBool "shows active" ("AWS_SESSION_TOKEN" `T.isInfixOf` result)

  , testCase "credentialDisplayName - empty = unknown" $
      credentialDisplayName (CredentialSourceStack []) @?= "unknown"

  -- 4. isNoUpdatesError
  , testCase "isNoUpdatesError - matches no-updates message" $ do
      let se = Amazonka.ServiceError' "cloudformation" status400 []
                 "ValidationError"
                 (Just "No updates are to be performed.")
                 Nothing
      isNoUpdatesError (Amazonka.ServiceError se) @?= True

  , testCase "isNoUpdatesError - no match on different message" $ do
      let se = Amazonka.ServiceError' "cloudformation" status400 []
                 "ValidationError"
                 (Just "Stack does not exist")
                 Nothing
      isNoUpdatesError (Amazonka.ServiceError se) @?= False

  , testCase "isNoUpdatesError - no match on missing message" $ do
      let se = Amazonka.ServiceError' "cloudformation" status400 []
                 "ValidationError"
                 Nothing
                 Nothing
      isNoUpdatesError (Amazonka.ServiceError se) @?= False

  -- 5. Event duration minimum 1 second
  , testCase "calculateEventDurations - sub-second rounds to 1" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          t05 = addUTCTime (secondsToNominalDiffTime 0.5) t0
          events =
            [ mkEvent "e1" "Res" "AWS::S3::Bucket" "CREATE_IN_PROGRESS" (Just t0)
            , mkEvent "e2" "Res" "AWS::S3::Bucket" "CREATE_COMPLETE" (Just t05)
            ]
          result = calculateEventDurations events
      assertEqual "sub-second -> 1" (Just 1) (sewDurationSeconds (result !! 1))

  , testCase "convertEventWithDuration - sub-second rounds to 1" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          t05 = addUTCTime (secondsToNominalDiffTime 0.1) t0
          event = SE.newStackEvent "stack-id" "e1" "test-stack" t05
          result = convertEventWithDuration t0 event
      assertEqual "sub-second -> 1" (Just 1) (sewDurationSeconds result)

  , testCase "convertEventWithDuration - exact 3 seconds" $ do
      let t0 = UTCTime (fromGregorian 2026 1 1) 0
          t3 = addUTCTime (secondsToNominalDiffTime 3) t0
          event = SE.newStackEvent "stack-id" "e1" "test-stack" t3
          result = convertEventWithDuration t0 event
      assertEqual "3 seconds" (Just 3) (sewDurationSeconds result)
  ]
