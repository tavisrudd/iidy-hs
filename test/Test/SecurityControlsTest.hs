module Test.SecurityControlsTest (securityControlsTests) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson (Value(..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool)

import Iidy.Constants (httpTimeoutSeconds, httpMaxResponseBytes, maxRegexPatternLength)
import Iidy.Yaml.Imports.Types (ImportType(..), ImportError(..), parseImportType)
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher)
import Iidy.Yaml.CustomResources.JsonSchema (validateSchema)
import Iidy.Yaml.CustomResources.Params
  ( ParamDef(..), validateParams )
import Iidy.Yaml.OValue (OValue(..))

securityControlsTests :: [TestTree]
securityControlsTests =
  [ testGroup "Import trust gate"   importTrustTests
  , testGroup "Regex length cap"    regexLengthTests
  , testGroup "HTTP limits"         httpLimitTests
  ]

------------------------------------------------------------------------
-- Import trust gate tests
------------------------------------------------------------------------

importTrustTests :: [TestTree]
importTrustTests =
  [ testGroup "parseImportType (pure)" parseImportTypeTests
  , testGroup "mkFullDispatcher enforcement" dispatcherEnforcementTests
  ]

parseImportTypeTests :: [TestTree]
parseImportTypeTests =
  [ testCase "local file from local base is OK" $
      parseImportType "file:foo.yaml" "."
        @?= Right ImportFile

  , testCase "env import from local base is OK" $
      parseImportType "env:MY_VAR" "."
        @?= Right ImportEnv

  , testCase "local file from s3 base is REJECTED" $ do
      let result = parseImportType "file:foo.yaml" "s3://bucket/base"
      case result of
        Left (ImportError e) ->
          assertBool "mentions not allowed from remote" ("not allowed from remote" `T.isInfixOf` e)
        Right _ -> fail "Expected Left for local import from remote base"

  , testCase "env import from https base is REJECTED" $ do
      let result = parseImportType "env:MY_VAR" "https://example.com"
      case result of
        Left (ImportError e) ->
          assertBool "mentions not allowed from remote" ("not allowed from remote" `T.isInfixOf` e)
        Right _ -> fail "Expected Left for env import from remote base"

  , testCase "git import from http base is REJECTED" $ do
      let result = parseImportType "git:sha" "http://example.com"
      case result of
        Left (ImportError e) ->
          assertBool "mentions not allowed from remote" ("not allowed from remote" `T.isInfixOf` e)
        Right _ -> fail "Expected Left for git import from remote base"

  , testCase "filehash import from s3 base is REJECTED" $ do
      let result = parseImportType "filehash:f" "s3://bucket/base"
      case result of
        Left (ImportError e) ->
          assertBool "mentions not allowed from remote" ("not allowed from remote" `T.isInfixOf` e)
        Right _ -> fail "Expected Left for filehash import from remote base"

  , testCase "remote s3 from s3 base is OK" $
      parseImportType "s3://bucket/k" "s3://bucket/base"
        @?= Right ImportS3

  , testCase "remote http from s3 base is OK" $
      parseImportType "http://x" "s3://bucket/base"
        @?= Right ImportHttp

  , testCase "ssm import from https base is OK" $
      parseImportType "ssm:/p" "https://example.com"
        @?= Right ImportSsm

  , testCase "unknown prefix 'bogus' is rejected with ImportError" $ do
      let result = parseImportType "bogus:x" "."
      case result of
        Left (ImportError e) ->
          assertBool "mentions 'bogus'" ("bogus" `T.isInfixOf` e)
        Right _ -> fail "Expected Left for unknown import prefix 'bogus'"

  , testCase "unknown prefix 'unknown' is rejected with ImportError" $ do
      let result = parseImportType "unknown:foo" "."
      case result of
        Left (ImportError e) ->
          assertBool "mentions 'unknown'" ("unknown" `T.isInfixOf` e)
        Right _ -> fail "Expected Left for unknown import prefix 'unknown'"

  , testCase "plain file path with no colon is still ImportFile" $
      parseImportType "plainfile.yaml" "."
        @?= Right ImportFile

  , testCase "relative path with colon in filename is still ImportFile" $
      parseImportType "./has:colon" "."
        @?= Right ImportFile
  ]

dispatcherEnforcementTests :: [TestTree]
dispatcherEnforcementTests =
  [ testCase "mkFullDispatcher rejects file: from s3 base" $ do
      result <- mkFullDispatcher Nothing "file:foo.yaml" "s3://bucket/base"
      case result of
        Left (ImportError e) ->
          assertBool "mentions not allowed" ("not allowed" `T.isInfixOf` e)
        Right _ -> fail "Expected Left for file: import from s3 base"

  , testCase "mkFullDispatcher rejects env: from https base" $ do
      result <- mkFullDispatcher Nothing "env:X" "https://example.com/base"
      case result of
        Left (ImportError e) ->
          assertBool "mentions not allowed" ("not allowed" `T.isInfixOf` e)
        Right _ -> fail "Expected Left for env: import from https base"
  ]

------------------------------------------------------------------------
-- Regex length cap tests
------------------------------------------------------------------------

regexLengthTests :: [TestTree]
regexLengthTests =
  [ testGroup "validateSchema pattern keyword" schemaPatternTests
  , testGroup "validateParams AllowedPattern"  paramsPatternTests
  ]

-- | Construct a JSON Schema with a pattern keyword.
patternSchema :: T.Text -> Value
patternSchema pat = Object (KM.fromList [("type", String "string"), ("pattern", String pat)])

schemaPatternTests :: [TestTree]
schemaPatternTests =
  [ testCase "pattern at max length (1024) is accepted" $ do
      -- Use a simple pattern padded to 1024 chars (avoid slow NFA compilation
      -- from long literal patterns on some platforms)
      let pat = "^x" <> T.replicate 1022 "."
      validateSchema (patternSchema pat) (String ("x" <> T.replicate 1022 "y"))
        @?= Right ()

  , testCase "pattern exceeding max length (1025) is rejected" $ do
      let pat = "^x" <> T.replicate 1023 "."
      let result = validateSchema (patternSchema pat) (String "anything")
      case result of
        Left e  -> assertBool "mentions exceeds maximum length" ("exceeds maximum length" `T.isInfixOf` e)
        Right _ -> fail "Expected Left for overlength pattern"

  , testCase "normal short pattern matching value is OK" $
      validateSchema (patternSchema "^[a-z]+$") (String "hello")
        @?= Right ()

  , testCase "normal short pattern non-matching value returns Left" $ do
      let result = validateSchema (patternSchema "^[a-z]+$") (String "HELLO")
      case result of
        Left e  -> assertBool "mentions does not match" ("does not match" `T.isInfixOf` e)
        Right _ -> fail "Expected Left for non-matching value"
  ]

-- | Build a minimal ParamDef for testing AllowedPattern validation.
mkParamDef :: T.Text -> Maybe T.Text -> ParamDef
mkParamDef name mPat = ParamDef
  { pdName           = name
  , pdDefault        = Nothing
  , pdType           = Nothing
  , pdAllowedValues  = Nothing
  , pdAllowedPattern = mPat
  , pdSchema         = Nothing
  , pdIsGlobal       = False
  }

paramsPatternTests :: [TestTree]
paramsPatternTests =
  [ testCase "overlength AllowedPattern (1025 chars) is rejected" $ do
      let pat = T.replicate 1025 "x"
          pd  = mkParamDef "MyParam" (Just pat)
          provided = Map.fromList [("MyParam", OString "anything")]
      let result = validateParams [pd] provided
      case result of
        Left e  -> assertBool "mentions exceeds maximum" ("exceeds maximum" `T.isInfixOf` e)
        Right _ -> fail "Expected Left for overlength AllowedPattern"

  , testCase "normal AllowedPattern with matching value is OK" $ do
      let pd       = mkParamDef "MyParam" (Just "^[a-z]+$")
          provided = Map.fromList [("MyParam", OString "hello")]
      validateParams [pd] provided @?= Right ()
  ]

------------------------------------------------------------------------
-- HTTP limit constant tests
------------------------------------------------------------------------

httpLimitTests :: [TestTree]
httpLimitTests =
  [ testCase "httpTimeoutSeconds is 30" $
      httpTimeoutSeconds @?= 30

  , testCase "httpMaxResponseBytes is 10 MiB (10485760)" $
      httpMaxResponseBytes @?= 10485760

  , testCase "maxRegexPatternLength is 1024" $
      maxRegexPatternLength @?= 1024
  ]
