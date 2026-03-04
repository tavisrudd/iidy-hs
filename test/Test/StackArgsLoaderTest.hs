module Test.StackArgsLoaderTest (stackArgsLoaderTests) where

import Control.Exception (try, SomeException)
import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict
import qualified Data.Text as T
import qualified Data.Vector as V
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Aws.CredentialSource (AwsSettings(..))
import Iidy.Cfn.StackArgsLoader (loadStackArgs, LoadedStackArgs(..), getStrListValidated, resolveEnvMaps, parseOnFailureText, parseCapabilityText, validateNoUnknownKeys, mergeAwsSettings, mergeSentinel, noProfileSentinel, noRoleSentinel)
import Iidy.Cfn.Types (CfnOperation(..), Capability(..), OnFailure(..), StackArgs(..))
import Iidy.Yaml.Imports.Types (RemoteImports(..))
import Test.Shared (noAwsSettings)

stackArgsLoaderTests :: [TestTree]
stackArgsLoaderTests =
  [ testCase "load basic stack args" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings AllowRemoteImports
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          saStackName sa @?= "test-stack"
          saTemplate sa @?= Just "template.yaml"
          saRegion sa @?= Just "us-east-1"

  , testCase "stack args tags include environment" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings AllowRemoteImports
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          case saTags sa of
            Nothing -> assertFailure "Expected tags"
            Just tags -> do
              assertBool "should have environment tag" $
                any (\(k, _) -> k == "environment") (Data.Map.Strict.toList tags)

  , testCase "stack args capabilities" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings AllowRemoteImports
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          saCapabilities sa @?= Just [CapIAM, CapNamedIAM]

  , testCase "stack args parameters" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings AllowRemoteImports
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          case saParameters sa of
            Nothing -> assertFailure "Expected parameters"
            Just params -> do
              Data.Map.Strict.lookup "Env" params @?= Just "dev"
              Data.Map.Strict.lookup "Version" params @?= Just "1.0"

  , testCase "environment map resolution" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args-envmap.yaml" "prod" OpUpdateStack noAwsSettings AllowRemoteImports
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          saRegion sa @?= Just "us-west-2"
          saProfile sa @?= Just "prod-profile"

  , testCase "environment map dev" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args-envmap.yaml" "dev" OpCreateStack noAwsSettings AllowRemoteImports
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          saRegion sa @?= Just "us-east-1"
          saProfile sa @?= Just "dev-profile"

  , testCase "CLI AWS settings override argsfile" $ do
      let cliAws = AwsSettings (Just "cli-profile") (Just "eu-west-1") Nothing
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack cliAws AllowRemoteImports
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs _sa aws _ctx) -> do
          awsProfile aws @?= Just "cli-profile"
          awsRegion aws @?= Just "eu-west-1"

  , testCase "missing argsfile throws" $ do
      result <- try @SomeException $
        loadStackArgs "nonexistent.yaml" "dev" OpCreateStack noAwsSettings AllowRemoteImports
      case result of
        Left _ex  -> pure ()
        Right _   -> assertFailure "Expected exception for missing file"

    -- H-1: resolveEnvMaps error tests (matching Rust behavior)
  , testCase "env map: missing env errors" $ do
      -- Region has a map but "staging" isn't in it
      let val = Object $ KM.fromList
            [ (Key.fromText "Region", Object $ KM.fromList
                [ (Key.fromText "dev", String "us-east-1")
                , (Key.fromText "prod", String "us-west-2")
                ])
            ]
      case resolveEnvMaps val "staging" of
        Left err -> do
          assertBool "error mentions environment name" $
            T.isInfixOf "staging" err
          assertBool "error mentions Region" $
            T.isInfixOf "Region" err
        Right _ -> assertFailure "Expected error for missing environment in map"

  , testCase "env map: non-string value errors" $ do
      -- Region map has the env but value is a number, not a string
      let val = Object $ KM.fromList
            [ (Key.fromText "Region", Object $ KM.fromList
                [ (Key.fromText "dev", Number 42)
                ])
            ]
      case resolveEnvMaps val "dev" of
        Left err ->
          assertBool "error mentions must map to strings" $
            T.isInfixOf "must map environments to strings" err
        Right _ -> assertFailure "Expected error for non-string value in env map"

  , testCase "env map: invalid type errors" $ do
      -- Region is an array, not a string or map
      let val = Object $ KM.fromList
            [ (Key.fromText "Region", Array mempty)
            ]
      case resolveEnvMaps val "dev" of
        Left err ->
          assertBool "error mentions must be string or environment map" $
            T.isInfixOf "must be a string or an environment map" err
        Right _ -> assertFailure "Expected error for invalid type"

  , testCase "env map: string value passes through" $ do
      let val = Object $ KM.fromList
            [ (Key.fromText "Region", String "us-east-1")
            ]
      case resolveEnvMaps val "dev" of
        Left err -> assertFailure $ "Unexpected error: " <> T.unpack err
        Right (Object obj) ->
          KM.lookup (Key.fromText "Region") obj @?= Just (String "us-east-1")
        Right _ -> assertFailure "Expected Object result"

  , testCase "env map: absent field passes through" $ do
      let val = Object $ KM.fromList
            [ (Key.fromText "StackName", String "my-stack")
            ]
      case resolveEnvMaps val "dev" of
        Left err -> assertFailure $ "Unexpected error: " <> T.unpack err
        Right _ -> pure ()  -- no error for absent env map fields

  , testCase "env map: missing env via loadStackArgs" $ do
      -- Use existing envmap fixture with an environment not in the map
      result <- loadStackArgs "test-fixtures/test-stack-args-envmap.yaml" "staging" OpCreateStack noAwsSettings AllowRemoteImports
      case result of
        Left err ->
          assertBool "error mentions environment name" $
            T.isInfixOf "staging" err
        Right _ -> assertFailure "Expected error for missing environment in env map"

    -- OnFailure parsing tests
  , testCase "parseOnFailureText: DO_NOTHING" $
      parseOnFailureText "DO_NOTHING" @?= Right DoNothing

  , testCase "parseOnFailureText: ROLLBACK" $
      parseOnFailureText "ROLLBACK" @?= Right Rollback

  , testCase "parseOnFailureText: DELETE" $
      parseOnFailureText "DELETE" @?= Right Delete

  , testCase "parseOnFailureText: case insensitive" $
      parseOnFailureText "do_nothing" @?= Right DoNothing

  , testCase "parseOnFailureText: unknown value errors" $
      case parseOnFailureText "INVALID" of
        Left err -> assertBool "error mentions INVALID" (T.isInfixOf "INVALID" err)
        Right _  -> assertFailure "Expected error for unknown OnFailure value"

    -- Capability parsing tests
  , testCase "parseCapabilityText: CAPABILITY_IAM" $
      parseCapabilityText "CAPABILITY_IAM" @?= Right CapIAM

  , testCase "parseCapabilityText: CAPABILITY_NAMED_IAM" $
      parseCapabilityText "CAPABILITY_NAMED_IAM" @?= Right CapNamedIAM

  , testCase "parseCapabilityText: CAPABILITY_AUTO_EXPAND" $
      parseCapabilityText "CAPABILITY_AUTO_EXPAND" @?= Right CapAutoExpand

  , testCase "parseCapabilityText: case insensitive" $
      parseCapabilityText "capability_iam" @?= Right CapIAM

  , testCase "parseCapabilityText: unknown value errors" $
      case parseCapabilityText "INVALID_CAP" of
        Left err -> assertBool "error mentions INVALID_CAP" (T.isInfixOf "INVALID_CAP" err)
        Right _  -> assertFailure "Expected error for unknown Capability value"

    -- Stack args loading with OnFailure
  , testCase "load stack args with OnFailure" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args-onfailure.yaml" "dev" OpCreateStack noAwsSettings AllowRemoteImports
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) ->
          saOnFailure sa @?= Just Rollback

    -- Error on unrecognized values
  , testCase "load stack args rejects unknown OnFailure" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args-bad-onfailure.yaml" "dev" OpCreateStack noAwsSettings AllowRemoteImports
      case result of
        Left err -> assertBool "error mentions unrecognized" (T.isInfixOf "unrecognized" err)
        Right _  -> assertFailure "Expected error for unknown OnFailure value"

  , testCase "load stack args rejects unknown Capability" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args-bad-capability.yaml" "dev" OpCreateStack noAwsSettings AllowRemoteImports
      case result of
        Left err -> assertBool "error mentions unrecognized" (T.isInfixOf "unrecognized" err)
        Right _  -> assertFailure "Expected error for unknown Capability value"

    -- Missing StackName validation
  , testCase "load stack args rejects missing StackName" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args-no-name.yaml" "dev" OpCreateStack noAwsSettings AllowRemoteImports
      case result of
        Left err -> assertBool "error mentions StackName is required" (T.isInfixOf "StackName is required" err)
        Right _  -> assertFailure "Expected error for missing StackName"

    -- getStrListValidated tests (Russell #3: no silent drops)
  , testCase "getStrListValidated: all strings succeeds" $ do
      let obj = KM.fromList
            [ (Key.fromText "Items", Array (V.fromList [String "a", String "b", String "c"]))
            ]
      getStrListValidated obj "Items" @?= Right (Just ["a", "b", "c"])

  , testCase "getStrListValidated: absent key returns Nothing" $
      getStrListValidated KM.empty "Items" @?= Right Nothing

  , testCase "getStrListValidated: null returns Nothing" $ do
      let obj = KM.fromList [(Key.fromText "Items", Null)]
      getStrListValidated obj "Items" @?= Right Nothing

  , testCase "getStrListValidated: number element errors" $ do
      let obj = KM.fromList
            [ (Key.fromText "NotificationARNs", Array (V.fromList
                [String "arn:aws:sns:us-east-1:123", Number 42]))
            ]
      case getStrListValidated obj "NotificationARNs" of
        Left err -> do
          assertBool "mentions field name" (T.isInfixOf "NotificationARNs" err)
          assertBool "mentions index" (T.isInfixOf "[1]" err)
          assertBool "mentions integer" (T.isInfixOf "integer" err)
        Right _ -> assertFailure "Expected error for non-string element"

  , testCase "getStrListValidated: boolean element errors" $ do
      let obj = KM.fromList
            [ (Key.fromText "CommandsBefore", Array (V.fromList [Bool True]))
            ]
      case getStrListValidated obj "CommandsBefore" of
        Left err -> do
          assertBool "mentions field name" (T.isInfixOf "CommandsBefore" err)
          assertBool "mentions boolean" (T.isInfixOf "boolean" err)
        Right _ -> assertFailure "Expected error for boolean element"

  , testCase "getStrListValidated: wrong type for key errors" $ do
      let obj = KM.fromList [(Key.fromText "Items", String "not-a-list")]
      case getStrListValidated obj "Items" of
        Left err -> assertBool "mentions expected sequence" (T.isInfixOf "sequence" err)
        Right _ -> assertFailure "Expected error for non-array value"

    -- Unknown key validation tests (1D)
  , testCase "validateNoUnknownKeys: typo Paramters suggests Parameters" $ do
      let obj = KM.fromList
            [ (Key.fromText "StackName", String "test")
            , (Key.fromText "Paramters", Object KM.empty)
            ]
      case validateNoUnknownKeys obj of
        Left err -> do
          assertBool "error mentions Paramters" (T.isInfixOf "Paramters" err)
          assertBool "error suggests Parameters" (T.isInfixOf "did you mean Parameters?" err)
        Right _ -> assertFailure "Expected error for unknown key Paramters"

  , testCase "validateNoUnknownKeys: far-off key has no suggestion" $ do
      let obj = KM.fromList
            [ (Key.fromText "StackName", String "test")
            , (Key.fromText "FooBarBazQux", String "whatever")
            ]
      case validateNoUnknownKeys obj of
        Left err -> do
          assertBool "error mentions FooBarBazQux" (T.isInfixOf "FooBarBazQux" err)
          assertBool "no suggestion" (not (T.isInfixOf "did you mean" err))
        Right _ -> assertFailure "Expected error for unknown key FooBarBazQux"

  , testCase "validateNoUnknownKeys: all valid keys pass" $ do
      let obj = KM.fromList
            [ (Key.fromText "StackName", String "test")
            , (Key.fromText "Template", String "t.yaml")
            , (Key.fromText "Parameters", Object KM.empty)
            , (Key.fromText "Tags", Object KM.empty)
            ]
      validateNoUnknownKeys obj @?= Right ()

  , testCase "validateNoUnknownKeys: $envValues is not flagged" $ do
      let obj = KM.fromList
            [ (Key.fromText "StackName", String "test")
            , (Key.fromText "$envValues", Object KM.empty)
            ]
      validateNoUnknownKeys obj @?= Right ()

  , testCase "loadStackArgs: unknown key fixture errors with suggestion" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args-unknown-key.yaml" "dev" OpCreateStack noAwsSettings AllowRemoteImports
      case result of
        Left err -> do
          assertBool "error mentions Paramters" (T.isInfixOf "Paramters" err)
          assertBool "error suggests Parameters" (T.isInfixOf "Parameters" err)
        Right _ -> assertFailure "Expected error for unknown key in fixture"

    -- Sentinel value tests (no-profile / no-role)
  , testCase "no-profile sentinel clears argsfile profile" $ do
      let cli = AwsSettings (Just noProfileSentinel) Nothing Nothing
          argsfile = AwsSettings (Just "prod-profile") (Just "us-east-1") Nothing
          merged = mergeAwsSettings cli argsfile
      awsProfile merged @?= Nothing
      awsRegion merged @?= Just "us-east-1"

  , testCase "no-role sentinel clears argsfile assume-role-arn" $ do
      let cli = AwsSettings Nothing Nothing (Just noRoleSentinel)
          argsfile = AwsSettings Nothing Nothing (Just "arn:aws:iam::123:role/Foo")
          merged = mergeAwsSettings cli argsfile
      awsAssumeRoleArn merged @?= Nothing

  , testCase "normal profile still overrides argsfile" $ do
      let cli = AwsSettings (Just "cli-profile") Nothing Nothing
          argsfile = AwsSettings (Just "argsfile-profile") Nothing Nothing
          merged = mergeAwsSettings cli argsfile
      awsProfile merged @?= Just "cli-profile"

  , testCase "mergeSentinel: sentinel returns Nothing" $
      mergeSentinel "no-profile" (Just "no-profile") (Just "inherited") @?= Nothing

  , testCase "mergeSentinel: non-sentinel passes through" $
      mergeSentinel "no-profile" (Just "real-profile") (Just "inherited") @?= Just "real-profile"

  , testCase "mergeSentinel: Nothing falls through to argsfile" $
      mergeSentinel "no-profile" Nothing (Just "inherited") @?= Just "inherited"
  ]
