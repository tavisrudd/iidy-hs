module Test.AwsLoaderTest (awsLoaderTests) where

import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool)

import qualified Amazonka.S3 as S3
import Iidy.Yaml.Imports.Loaders.S3 (parseS3Uri)
import Iidy.Yaml.Imports.Loaders.Ssm (parseSsmLocation)
import Iidy.Yaml.Imports.Loaders.SsmPath (parseSsmPathLocation)
import Iidy.Yaml.Imports.Loaders.Cfn (parseCfnLocation)
import Iidy.Yaml.Imports.Types (ImportError(..))

awsLoaderTests :: [TestTree]
awsLoaderTests =
  [ testGroup "S3 URI parsing" s3Tests
  , testGroup "SSM location parsing" ssmTests
  , testGroup "SSM path location parsing" ssmPathTests
  , testGroup "CFN location parsing" cfnTests
  ]

------------------------------------------------------------------------
-- S3 URI parsing
------------------------------------------------------------------------

s3Tests :: [TestTree]
s3Tests =
  [ testCase "parses //bucket/key" $
      parseS3Uri "//my-bucket/path/to/file.yaml" @?=
        Right (S3.BucketName "my-bucket", S3.ObjectKey "path/to/file.yaml")

  , testCase "parses bucket/key without //" $
      parseS3Uri "my-bucket/path/to/file.yaml" @?=
        Right (S3.BucketName "my-bucket", S3.ObjectKey "path/to/file.yaml")

  , testCase "key with nested slashes" $
      parseS3Uri "//bucket/a/b/c/d.json" @?=
        Right (S3.BucketName "bucket", S3.ObjectKey "a/b/c/d.json")

  , testCase "empty bucket name errors" $
      case parseS3Uri "///" of
        Left (ImportError e) -> assertBool "mentions empty bucket" ("empty bucket" `T.isInfixOf` e)
        Right _ -> fail "Expected error for empty bucket"

  , testCase "missing key errors" $
      case parseS3Uri "bucket-only" of
        Left (ImportError e) -> assertBool "mentions missing key" ("missing key" `T.isInfixOf` e)
        Right _ -> fail "Expected error for missing key"

  , testCase "empty key errors" $
      case parseS3Uri "bucket/" of
        Left (ImportError e) -> assertBool "mentions empty key" ("empty key" `T.isInfixOf` e)
        Right _ -> fail "Expected error for empty key"
  ]

------------------------------------------------------------------------
-- SSM location parsing
------------------------------------------------------------------------

ssmTests :: [TestTree]
ssmTests =
  [ testCase "plain parameter path" $ do
      let Right (name, fmt) = parseSsmLocation "ssm:/app/config/database"
      name @?= "/app/config/database"
      fmt @?= Nothing

  , testCase "parameter with :json suffix" $ do
      let Right (name, fmt) = parseSsmLocation "ssm:/app/config/api:json"
      name @?= "/app/config/api"
      fmt @?= Just "json"

  , testCase "parameter with :yaml suffix" $ do
      let Right (name, fmt) = parseSsmLocation "ssm:/app/config/cache:yaml"
      name @?= "/app/config/cache"
      fmt @?= Just "yaml"

  , testCase "parameter with unknown suffix treated as path" $ do
      let Right (name, fmt) = parseSsmLocation "ssm:/app/config:xml"
      name @?= "/app/config:xml"
      fmt @?= Nothing

  , testCase "bare parameter name (no slash)" $ do
      let Right (name, fmt) = parseSsmLocation "ssm:my-param"
      name @?= "my-param"
      fmt @?= Nothing

  , testCase "without ssm: prefix works" $ do
      let Right (name, fmt) = parseSsmLocation "/app/config"
      name @?= "/app/config"
      fmt @?= Nothing
  ]

------------------------------------------------------------------------
-- SSM path location parsing
------------------------------------------------------------------------

ssmPathTests :: [TestTree]
ssmPathTests =
  [ testCase "plain path" $ do
      let Right (path, fmt) = parseSsmPathLocation "ssm-path:/app/config"
      path @?= "/app/config"
      fmt @?= Nothing

  , testCase "path with :json suffix" $ do
      let Right (path, fmt) = parseSsmPathLocation "ssm-path:/app/config:json"
      path @?= "/app/config"
      fmt @?= Just "json"

  , testCase "path with :yaml suffix" $ do
      let Right (path, fmt) = parseSsmPathLocation "ssm-path:/app/config:yaml"
      path @?= "/app/config"
      fmt @?= Just "yaml"

  , testCase "path with unknown suffix treated as path" $ do
      let Right (path, fmt) = parseSsmPathLocation "ssm-path:/app/config:xml"
      path @?= "/app/config:xml"
      fmt @?= Nothing

  , testCase "empty path errors" $
      case parseSsmPathLocation "ssm-path:" of
        Left (ImportError e) -> assertBool "mentions invalid" ("Invalid" `T.isInfixOf` e)
        Right _ -> fail "Expected error for empty path"

  , testCase "without prefix works" $ do
      let Right (path, fmt) = parseSsmPathLocation "/app/config"
      path @?= "/app/config"
      fmt @?= Nothing
  ]

------------------------------------------------------------------------
-- CFN location parsing
------------------------------------------------------------------------

cfnTests :: [TestTree]
cfnTests =
  [ testCase "cfn:output:Stack/Key parses correctly" $ do
      let Right (field, loc) = parseCfnLocation "cfn:output:my-stack/VpcId"
      show field @?= "CfnOutput"
      loc @?= "my-stack/VpcId"

  , testCase "cfn:output:Stack (all outputs)" $ do
      let Right (field, loc) = parseCfnLocation "cfn:output:my-stack"
      show field @?= "CfnOutput"
      loc @?= "my-stack"

  , testCase "cfn:export:Name parses correctly" $ do
      let Right (field, loc) = parseCfnLocation "cfn:export:my-export"
      show field @?= "CfnExport"
      loc @?= "my-export"

  , testCase "cfn:parameter:Stack/Key parses correctly" $ do
      let Right (field, loc) = parseCfnLocation "cfn:parameter:my-stack/DbHost"
      show field @?= "CfnParameter"
      loc @?= "my-stack/DbHost"

  , testCase "cfn:tag:Stack/Key parses correctly" $ do
      let Right (field, loc) = parseCfnLocation "cfn:tag:my-stack/Environment"
      show field @?= "CfnTag"
      loc @?= "my-stack/Environment"

  , testCase "cfn:resource:Stack/LogicalId parses correctly" $ do
      let Right (field, loc) = parseCfnLocation "cfn:resource:my-stack/MyBucket"
      show field @?= "CfnResource"
      loc @?= "my-stack/MyBucket"

  , testCase "cfn:stack:Stack parses correctly" $ do
      let Right (field, loc) = parseCfnLocation "cfn:stack:my-stack"
      show field @?= "CfnStack"
      loc @?= "my-stack"

  , testCase "invalid sub-type errors" $
      case parseCfnLocation "cfn:bogus:my-stack" of
        Left (ImportError e) -> assertBool "mentions invalid" ("Invalid cfn sub-type" `T.isInfixOf` e)
        Right _ -> fail "Expected error for invalid sub-type"

  , testCase "missing field errors" $
      case parseCfnLocation "cfn:my-stack" of
        Left _ -> pure ()
        Right _ -> fail "Expected error for missing field"

  , testCase "bare cfn:Stack/Key shorthand rejected" $
      -- JS does not support cfn:Stack/Key without a subtype field
      -- "Stack/Key" is not a valid field name
      case parseCfnLocation "cfn:Stack/Key" of
        Left _ -> pure ()
        Right _ -> fail "Expected error for bare cfn:Stack/Key (no subtype)"
  ]
