module Test.AwsLoaderTest (awsLoaderTests) where

import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool)

import qualified Amazonka.S3 as S3
import Iidy.Yaml.Imports.Loaders.S3 (parseS3Uri)
import Iidy.Yaml.Imports.Loaders.Ssm (parseSsmLocation)
import Iidy.Yaml.Imports.Loaders.Cfn (parseCfnRef)
import Iidy.Yaml.Imports.Types (ImportError(..))

awsLoaderTests :: [TestTree]
awsLoaderTests =
  [ testGroup "S3 URI parsing" s3Tests
  , testGroup "SSM location parsing" ssmTests
  , testGroup "CFN reference parsing" cfnTests
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
-- CFN reference parsing
------------------------------------------------------------------------

cfnTests :: [TestTree]
cfnTests =
  [ testCase "slash separator" $
      parseCfnRef "my-stack/VpcId" @?= Right ("my-stack", "VpcId")

  , testCase "dot separator not supported" $
      case parseCfnRef "my-stack.VpcId" of
        Left _ -> pure ()
        Right _ -> fail "Dot separator should not be supported"

  , testCase "empty stack name errors" $
      case parseCfnRef "/VpcId" of
        Left (ImportError e) -> assertBool "mentions empty stack" ("empty stack name" `T.isInfixOf` e)
        Right _ -> fail "Expected error for empty stack name"

  , testCase "empty output key errors" $
      case parseCfnRef "my-stack/" of
        Left (ImportError e) -> assertBool "mentions empty output" ("empty output key" `T.isInfixOf` e)
        Right _ -> fail "Expected error for empty output key"

  , testCase "no separator errors" $
      case parseCfnRef "no-separator" of
        Left (ImportError e) -> assertBool "mentions format" ("stackName/outputKey" `T.isInfixOf` e
                                  || "CFN reference" `T.isInfixOf` e)
        Right _ -> fail "Expected error for no separator"
  ]
