module Test.SecurityControlsTest (securityControlsTests) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Iidy.Constants (httpMaxResponseBytes, httpTimeoutSeconds, maxRegexPatternLength)
import Iidy.Yaml.CustomResources.JsonSchema (validateSchema)
import Iidy.Yaml.CustomResources.Params (
    ParamDef (..),
    validateParams,
 )
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig, mkFullDispatcher, mkImportConfig)
import Iidy.Yaml.Imports.Types (ImportError (..), ImportType (..), RemoteImports (..), importPolicy, parseImportType)
import Iidy.Yaml.OValue (OValue (..))

securityControlsTests :: [TestTree]
securityControlsTests =
    [ testGroup "Import trust gate" importTrustTests
    , testGroup "Regex length cap" regexLengthTests
    , testGroup "HTTP limits" httpLimitTests
    ]

------------------------------------------------------------------------
-- Import classification tests (the trust-gate matrix lives in
-- Test.ImportTrustTest)
------------------------------------------------------------------------

importTrustTests :: [TestTree]
importTrustTests =
    [ testGroup "parseImportType (pure)" parseImportTypeTests
    , testGroup "--no-remote-imports enforcement" noRemoteImportsTests
    ]

parseImportTypeTests :: [TestTree]
parseImportTypeTests =
    [ testCase "unknown prefix 'bogus' is rejected with ImportError" $ do
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

------------------------------------------------------------------------
-- --no-remote-imports tests
------------------------------------------------------------------------

-- | ImportConfig with remote imports blocked (simulates --no-remote-imports).
blockedCfg :: ImportConfig
blockedCfg = mkImportConfig Nothing (importPolicy BlockRemoteImports)

noRemoteImportsTests :: [TestTree]
noRemoteImportsTests =
    [ testCase "http: import blocked when remote imports disabled" $ do
        result <- mkFullDispatcher blockedCfg "http://example.com/data.json" "."
        case result of
            Left (ImportError e) ->
                assertBool "mentions --no-remote-imports" ("--no-remote-imports" `T.isInfixOf` e)
            Right _ -> fail "Expected Left for http: with remote imports disabled"
    , testCase "https: import blocked when remote imports disabled" $ do
        result <- mkFullDispatcher blockedCfg "https://example.com/data.json" "."
        case result of
            Left (ImportError e) ->
                assertBool "mentions --no-remote-imports" ("--no-remote-imports" `T.isInfixOf` e)
            Right _ -> fail "Expected Left for https: with remote imports disabled"
    , testCase "s3: import blocked when remote imports disabled" $ do
        result <- mkFullDispatcher blockedCfg "s3://bucket/key.yaml" "."
        case result of
            Left (ImportError e) ->
                assertBool "mentions --no-remote-imports" ("--no-remote-imports" `T.isInfixOf` e)
            Right _ -> fail "Expected Left for s3: with remote imports disabled"
    , testCase "env: import still works when remote imports disabled" $ do
        result <- mkFullDispatcher blockedCfg "env:HOME" "."
        case result of
            Left (ImportError e) -> fail $ "Expected Right for env: import, got: " <> T.unpack e
            Right _ -> pure ()
    , testCase "file: import still works when remote imports disabled" $ do
        result <- mkFullDispatcher blockedCfg "file:test-fixtures/test-stack-args.yaml" "."
        case result of
            Left (ImportError e) -> fail $ "Expected Right for file: import, got: " <> T.unpack e
            Right _ -> pure ()
    , testCase "cfn: import requires AWS env (not blocked by --no-remote-imports)" $ do
        -- cfn: without AWS env gives "requires credentials" not "--no-remote-imports"
        result <- mkFullDispatcher blockedCfg "cfn:stack/key" "."
        case result of
            Left (ImportError e) ->
                assertBool
                    "mentions credentials, not --no-remote-imports"
                    ("credentials" `T.isInfixOf` e && not ("--no-remote-imports" `T.isInfixOf` e))
            Right _ -> fail "Expected Left for cfn: without AWS env"
    , testCase "ssm: import requires AWS env (not blocked by --no-remote-imports)" $ do
        result <- mkFullDispatcher blockedCfg "ssm:/param" "."
        case result of
            Left (ImportError e) ->
                assertBool
                    "mentions credentials, not --no-remote-imports"
                    ("credentials" `T.isInfixOf` e && not ("--no-remote-imports" `T.isInfixOf` e))
            Right _ -> fail "Expected Left for ssm: without AWS env"
    ]

------------------------------------------------------------------------
-- Regex length cap tests
------------------------------------------------------------------------

regexLengthTests :: [TestTree]
regexLengthTests =
    [ testGroup "validateSchema pattern keyword" schemaPatternTests
    , testGroup "validateParams AllowedPattern" paramsPatternTests
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
            Left e -> assertBool "mentions exceeds maximum length" ("exceeds maximum length" `T.isInfixOf` e)
            Right _ -> fail "Expected Left for overlength pattern"
    , testCase "normal short pattern matching value is OK" $
        validateSchema (patternSchema "^[a-z]+$") (String "hello")
            @?= Right ()
    , testCase "normal short pattern non-matching value returns Left" $ do
        let result = validateSchema (patternSchema "^[a-z]+$") (String "HELLO")
        case result of
            Left e -> assertBool "mentions does not match" ("does not match" `T.isInfixOf` e)
            Right _ -> fail "Expected Left for non-matching value"
    ]

-- | Build a minimal ParamDef for testing AllowedPattern validation.
mkParamDef :: T.Text -> Maybe T.Text -> ParamDef
mkParamDef name mPat =
    ParamDef
        { pdName = name
        , pdDefault = Nothing
        , pdType = Nothing
        , pdAllowedValues = Nothing
        , pdAllowedPattern = mPat
        , pdSchema = Nothing
        , pdIsGlobal = False
        }

paramsPatternTests :: [TestTree]
paramsPatternTests =
    [ testCase "overlength AllowedPattern (1025 chars) is rejected" $ do
        let pat = T.replicate 1025 "x"
            pd = mkParamDef "MyParam" (Just pat)
            provided = Map.fromList [("MyParam", OString "anything")]
        let result = validateParams [pd] provided
        case result of
            Left e -> assertBool "mentions exceeds maximum" ("exceeds maximum" `T.isInfixOf` e)
            Right _ -> fail "Expected Left for overlength AllowedPattern"
    , testCase "normal AllowedPattern with matching value is OK" $ do
        let pd = mkParamDef "MyParam" (Just "^[a-z]+$")
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
