module Test.AwsLoaderTest (awsLoaderTests) where

import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool, assertFailure)

import qualified Amazonka.S3 as S3
import Iidy.Yaml.Imports.Loaders.S3 (parseS3Uri)
import Iidy.Yaml.Imports.Loaders.Ssm (parseSsmLocation, parseSsmPathLocation, buildResultObject, stripPathPrefix)
import Iidy.Yaml.Imports.Loaders.Cfn (parseCfnLocation, CfnField(..))
import Iidy.Yaml.Imports.Types (ImportError(..))

awsLoaderTests :: [TestTree]
awsLoaderTests =
  [ testGroup "S3 URI parsing" s3Tests
  , testGroup "SSM location parsing" ssmTests
  , testGroup "SSM path location parsing" ssmPathTests
  , testGroup "SSM path result building" ssmPathResultTests
  , testGroup "CFN location parsing" cfnTests
  ]

-- | Assert that a parse result is Right and run assertions on the value.
assertRight :: Show e => Either e a -> (a -> IO ()) -> IO ()
assertRight (Left err) _ = assertFailure $ "parse failed: " <> show err
assertRight (Right val) f = f val

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
  [ testCase "plain parameter path" $
      assertRight (parseSsmLocation "ssm:/app/config/database") $ \(name, fmt) -> do
        name @?= "/app/config/database"
        fmt @?= Nothing

  , testCase "parameter with :json suffix" $
      assertRight (parseSsmLocation "ssm:/app/config/api:json") $ \(name, fmt) -> do
        name @?= "/app/config/api"
        fmt @?= Just "json"

  , testCase "parameter with :yaml suffix" $
      assertRight (parseSsmLocation "ssm:/app/config/cache:yaml") $ \(name, fmt) -> do
        name @?= "/app/config/cache"
        fmt @?= Just "yaml"

  , testCase "parameter with unknown suffix treated as path" $
      assertRight (parseSsmLocation "ssm:/app/config:xml") $ \(name, fmt) -> do
        name @?= "/app/config:xml"
        fmt @?= Nothing

  , testCase "bare parameter name (no slash)" $
      assertRight (parseSsmLocation "ssm:my-param") $ \(name, fmt) -> do
        name @?= "my-param"
        fmt @?= Nothing

  , testCase "without ssm: prefix works" $
      assertRight (parseSsmLocation "/app/config") $ \(name, fmt) -> do
        name @?= "/app/config"
        fmt @?= Nothing
  ]

------------------------------------------------------------------------
-- SSM path location parsing
------------------------------------------------------------------------

ssmPathTests :: [TestTree]
ssmPathTests =
  [ testCase "plain path" $
      assertRight (parseSsmPathLocation "ssm-path:/app/config") $ \(path, fmt) -> do
        path @?= "/app/config"
        fmt @?= Nothing

  , testCase "path with :json suffix" $
      assertRight (parseSsmPathLocation "ssm-path:/app/config:json") $ \(path, fmt) -> do
        path @?= "/app/config"
        fmt @?= Just "json"

  , testCase "path with :yaml suffix" $
      assertRight (parseSsmPathLocation "ssm-path:/app/config:yaml") $ \(path, fmt) -> do
        path @?= "/app/config"
        fmt @?= Just "yaml"

  , testCase "path with unknown suffix treated as path" $
      assertRight (parseSsmPathLocation "ssm-path:/app/config:xml") $ \(path, fmt) -> do
        path @?= "/app/config:xml"
        fmt @?= Nothing

  , testCase "empty path errors" $
      case parseSsmPathLocation "ssm-path:" of
        Left (ImportError e) -> assertBool "mentions invalid" ("Invalid" `T.isInfixOf` e)
        Right _ -> fail "Expected error for empty path"

  , testCase "without prefix works" $
      assertRight (parseSsmPathLocation "/app/config") $ \(path, fmt) -> do
        path @?= "/app/config"
        fmt @?= Nothing
  ]

------------------------------------------------------------------------
-- SSM path result building (pagination correctness)
--
-- These test the pure functions that process parameter lists, verifying
-- they work correctly with >10 parameters -- the number that would be
-- returned from a single SSM API page. Prior to the pagination fix,
-- fetchParametersByPath used Amazonka.send (single page, max 10 results)
-- instead of Amazonka.paginate, silently truncating results.
------------------------------------------------------------------------

ssmPathResultTests :: [TestTree]
ssmPathResultTests =
  [ testCase "stripPathPrefix removes base path" $
      stripPathPrefix "/app/config" "/app/config/database/host"
        @?= "database/host"

  , testCase "stripPathPrefix with trailing slash" $
      stripPathPrefix "/app/config/" "/app/config/key"
        @?= "key"

  , testCase "stripPathPrefix non-matching strips leading slash" $
      -- When the prefix doesn't match, the name is kept but leading / is still stripped
      stripPathPrefix "/other" "/app/config/key"
        @?= "app/config/key"

  , testCase "buildResultObject with empty params" $ do
      let result = buildResultObject "/app/" Nothing []
      result @?= Object KM.empty

  , testCase "buildResultObject with single param" $ do
      let result = buildResultObject "/app" Nothing [("/app/key", "val")]
      result @?= Object (KM.fromList [(Key.fromText "key", String "val")])

  , testCase "buildResultObject with >10 params (multi-page simulation)" $ do
      -- Simulate 15 params that would result from paginating 2 pages
      let basePath = "/app/config"
          params = [ ("/app/config/param-" <> T.pack (show i),
                      "value-" <> T.pack (show i))
                   | i <- [1..15 :: Int]
                   ]
          result = buildResultObject basePath Nothing params
      case result of
        Object km -> do
          -- All 15 keys should be present
          KM.size km @?= 15
          -- Verify first and last keys
          KM.lookup (Key.fromText "param-1") km
            @?= Just (String "value-1")
          KM.lookup (Key.fromText "param-15") km
            @?= Just (String "value-15")
        _ -> assertFailure "Expected Object"

  , testCase "buildResultObject with 25 params (3-page simulation)" $ do
      -- Simulate 25 params that would span 3 pages (10+10+5)
      let basePath = "/prod/settings"
          params = [ ("/prod/settings/s" <> T.pack (show i),
                      "v" <> T.pack (show i))
                   | i <- [1..25 :: Int]
                   ]
          result = buildResultObject basePath Nothing params
      case result of
        Object km -> do
          KM.size km @?= 25
          -- Verify a sampling across all pages
          KM.lookup (Key.fromText "s1") km @?= Just (String "v1")
          KM.lookup (Key.fromText "s10") km @?= Just (String "v10")
          KM.lookup (Key.fromText "s11") km @?= Just (String "v11")
          KM.lookup (Key.fromText "s20") km @?= Just (String "v20")
          KM.lookup (Key.fromText "s25") km @?= Just (String "v25")
        _ -> assertFailure "Expected Object"

  , testCase "buildResultObject with :json format and >10 params" $ do
      let basePath = "/app"
          params = [ ("/app/json-" <> T.pack (show i),
                      "{\"n\":" <> T.pack (show i) <> "}")
                   | i <- [1..12 :: Int]
                   ]
          result = buildResultObject basePath (Just "json") params
      case result of
        Object km -> do
          KM.size km @?= 12
          -- Each value should be parsed as JSON object, not string
          case KM.lookup (Key.fromText "json-1") km of
            Just (Object inner) ->
              KM.lookup (Key.fromText "n") inner @?= Just (Number 1)
            other -> assertFailure $ "Expected parsed JSON object, got: " <> show other
        _ -> assertFailure "Expected Object"
  ]

------------------------------------------------------------------------
-- CFN location parsing
------------------------------------------------------------------------

cfnTests :: [TestTree]
cfnTests =
  [ testCase "cfn:output:Stack/Key parses correctly" $
      assertRight (parseCfnLocation "cfn:output:my-stack/VpcId") $ \(field, loc) -> do
        show field @?= "CfnOutput"
        loc @?= "my-stack/VpcId"

  , testCase "cfn:output:Stack (all outputs)" $
      assertRight (parseCfnLocation "cfn:output:my-stack") $ \(field, loc) -> do
        show field @?= "CfnOutput"
        loc @?= "my-stack"

  , testCase "cfn:export:Name parses correctly" $
      assertRight (parseCfnLocation "cfn:export:my-export") $ \(field, loc) -> do
        show field @?= "CfnExport"
        loc @?= "my-export"

  , testCase "cfn:parameter:Stack/Key parses correctly" $
      assertRight (parseCfnLocation "cfn:parameter:my-stack/DbHost") $ \(field, loc) -> do
        show field @?= "CfnParameter"
        loc @?= "my-stack/DbHost"

  , testCase "cfn:tag:Stack/Key parses correctly" $
      assertRight (parseCfnLocation "cfn:tag:my-stack/Environment") $ \(field, loc) -> do
        show field @?= "CfnTag"
        loc @?= "my-stack/Environment"

  , testCase "cfn:resource:Stack/LogicalId parses correctly" $
      assertRight (parseCfnLocation "cfn:resource:my-stack/MyBucket") $ \(field, loc) -> do
        show field @?= "CfnResource"
        loc @?= "my-stack/MyBucket"

  , testCase "cfn:stack:Stack parses correctly" $
      assertRight (parseCfnLocation "cfn:stack:my-stack") $ \(field, loc) -> do
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

  , testCase "cfn:parameter:Stack (all parameters)" $
      assertRight (parseCfnLocation "cfn:parameter:my-stack") $ \(field, loc) -> do
        field @?= CfnParameter
        loc @?= "my-stack"

  , testCase "cfn:tag:Stack (all tags)" $
      assertRight (parseCfnLocation "cfn:tag:my-stack") $ \(field, loc) -> do
        field @?= CfnTag
        loc @?= "my-stack"

  , testCase "cfn:resource:Stack (all resources)" $
      assertRight (parseCfnLocation "cfn:resource:my-stack") $ \(field, loc) -> do
        field @?= CfnResource
        loc @?= "my-stack"

  , testCase "cfn:export: parses with empty name" $
      assertRight (parseCfnLocation "cfn:export:") $ \(field, loc) -> do
        field @?= CfnExport
        loc @?= ""

  , testCase "cfn:stack: parses with empty name" $
      assertRight (parseCfnLocation "cfn:stack:") $ \(field, loc) -> do
        field @?= CfnStack
        loc @?= ""
  ]
