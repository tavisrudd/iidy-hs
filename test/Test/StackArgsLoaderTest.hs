module Test.StackArgsLoaderTest (stackArgsLoaderTests) where

import Control.Exception (try, SomeException)
import qualified Data.Map.Strict
import qualified Data.Text as T
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Aws.CredentialSource (AwsSettings(..))
import Iidy.Cfn.StackArgsLoader (loadStackArgs, LoadedStackArgs(..))
import Iidy.Cfn.Types (CfnOperation(..), StackArgs(..))
import Test.Shared (noAwsSettings)

stackArgsLoaderTests :: [TestTree]
stackArgsLoaderTests =
  [ testCase "load basic stack args" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          saStackName sa @?= Just "test-stack"
          saTemplate sa @?= Just "template.yaml"
          saRegion sa @?= Just "us-east-1"

  , testCase "stack args tags include environment" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          case saTags sa of
            Nothing -> assertFailure "Expected tags"
            Just tags -> do
              assertBool "should have environment tag" $
                any (\(k, _) -> k == "environment") (Data.Map.Strict.toList tags)

  , testCase "stack args capabilities" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          saCapabilities sa @?= Just ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]

  , testCase "stack args parameters" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          case saParameters sa of
            Nothing -> assertFailure "Expected parameters"
            Just params -> do
              Data.Map.Strict.lookup "Env" params @?= Just "dev"
              Data.Map.Strict.lookup "Version" params @?= Just "1.0"

  , testCase "environment map resolution" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args-envmap.yaml" "prod" OpUpdateStack noAwsSettings
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          saRegion sa @?= Just "us-west-2"
          saProfile sa @?= Just "prod-profile"

  , testCase "environment map dev" $ do
      result <- loadStackArgs "test-fixtures/test-stack-args-envmap.yaml" "dev" OpCreateStack noAwsSettings
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs sa _aws _ctx) -> do
          saRegion sa @?= Just "us-east-1"
          saProfile sa @?= Just "dev-profile"

  , testCase "CLI AWS settings override argsfile" $ do
      let cliAws = AwsSettings (Just "cli-profile") (Just "eu-west-1") Nothing
      result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack cliAws
      case result of
        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
        Right (LoadedStackArgs _sa aws _ctx) -> do
          awsProfile aws @?= Just "cli-profile"
          awsRegion aws @?= Just "eu-west-1"

  , testCase "missing argsfile throws" $ do
      result <- try @SomeException $
        loadStackArgs "nonexistent.yaml" "dev" OpCreateStack noAwsSettings
      case result of
        Left _ex  -> pure ()
        Right _   -> assertFailure "Expected exception for missing file"
  ]
