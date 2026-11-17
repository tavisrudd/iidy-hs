{- | The AWS-backed import gate (card C15): a document whose base is not
trusted may not import @cfn:@, @ssm:@, @ssm-path:@ or @s3:@; a local
document and one under a @--trust-import-source@ prefix may. Every case
runs the real dispatcher with a mock AWS environment, so a refused import
is shown to make no AWS request.
-}
module Test.AwsImportGateTest (awsImportGateTests) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Iidy.Yaml.Engine (PreprocessError (..), PreprocessResult (..))
import Iidy.Yaml.Imports.Loaders.Dispatch (mkFullDispatcher, mkImportConfig)
import Iidy.Yaml.Imports.Types (ImportData, ImportError (..), ImportPolicy, RemoteImports (..), importPolicy, rootBase)
import Iidy.Yaml.OValue (toValue)
import Test.ImportFixtures (flagPolicy, preprocessText, stubDocLoader)
import Test.MockAws (MockAws (..), newMockAws)

awsImportGateTests :: [TestTree]
awsImportGateTests =
    [ testGroup "local base may import AWS-backed types" (allowedMatrix [] localBases)
    , testGroup "trusted base may import AWS-backed types" (allowedMatrix trustedPrefixes trustedBases)
    , testGroup "base outside the trusted prefixes is refused" refusedMatrix
    , testGroup "remote document importing ssm: through the engine" engineCases
    ]

------------------------------------------------------------------------
-- Tables
------------------------------------------------------------------------

awsLocations :: [Text]
awsLocations =
    [ "ssm:/app/db-host"
    , "ssm-path:/app"
    , "cfn:output:network-stack/VpcId"
    , "s3:bucket/data.yaml"
    , "s3://bucket/data.yaml"
    ]

localBases :: [Text]
localBases = ["stack-args.yaml", "dir/template.yaml", "/abs/template.yaml", "-"]

trustedPrefixes :: [Text]
trustedPrefixes = ["https://t.example.com/", "s3://tmpl/", "s3:tmpl/", "ssm:/tmpl/"]

trustedBases :: [Text]
trustedBases =
    [ "https://t.example.com/a.yaml"
    , "s3://tmpl/dir/a.yaml"
    , "s3:tmpl/a.yaml"
    , "ssm:/tmpl/a"
    ]

-- | Bases next to, but outside, 'trustedPrefixes'.
outsideBases :: [Text]
outsideBases =
    [ "https://t.example.com.evil/a.yaml"
    , "http://t.example.com/a.yaml"
    , "s3://tmpl2/a.yaml"
    , "s3:tmpl/../x/a.yaml"
    , "ssm:/tmpl2/a"
    , "cfn:export/Tmpl"
    ]

------------------------------------------------------------------------
-- Dispatcher
------------------------------------------------------------------------

{- | The gate lets the import through: the result is not a trust refusal
(a missing mock fixture may still fail the load itself), and @ssm:@
actually resolves from the mock.
-}
allowedMatrix :: [Text] -> [Text] -> [TestTree]
allowedMatrix prefixes bases =
    [ testCase (T.unpack (loc <> " from " <> base)) $ do
        policy <- flagPolicy prefixes
        (_mock, result) <- dispatchWithMock policy loc base
        case result of
            Left (ImportError e) ->
                assertBool ("refused by the trust gate: " <> T.unpack e) (not (isTrustRefusal e))
            Right _ok -> pure ()
        assertBool "ssm: resolves" (loc /= "ssm:/app/db-host" || either (const False) (const True) result)
    | base <- bases
    , loc <- awsLocations
    ]

refusedMatrix :: [TestTree]
refusedMatrix =
    [ testCase (T.unpack (loc <> " from " <> base)) $ do
        policy <- flagPolicy trustedPrefixes
        (mock, result) <- dispatchWithMock policy loc base
        case result of
            Left (ImportError e) -> do
                assertBool ("expected a trust refusal, got: " <> T.unpack e) (isTrustRefusal e)
                assertBool "error names the base" (base `T.isInfixOf` e)
                assertBool "error suggests the flag" ("--trust-import-source" `T.isInfixOf` e)
            Right _ok -> assertFailure "AWS-backed import allowed from an untrusted base"
        readIORef (mockRequests mock) >>= (@?= [])
    | base <- outsideBases
    , loc <- awsLocations
    ]

dispatchWithMock :: ImportPolicy -> Text -> Text -> IO (MockAws, Either ImportError ImportData)
dispatchWithMock policy loc base = do
    mock <- newMockAws
    result <- mkFullDispatcher (mkImportConfig (Just (mockEnv mock)) policy) loc (rootBase base)
    pure (mock, result)

isTrustRefusal :: Text -> Bool
isTrustRefusal e = "not allowed from remote" `T.isInfixOf` e && "not a trusted source" `T.isInfixOf` e

------------------------------------------------------------------------
-- Engine: a local template imports a remote document that imports ssm:
------------------------------------------------------------------------

remoteDoc :: Text
remoteDoc = "https://t.example.com/r.yaml"

remoteSource :: Text
remoteSource = "$defs:\n  own: x\n$imports:\n  p: ssm:/app/db-host\nvalue: \"{{p}}\"\n"

rootSource :: Text
rootSource = "$imports:\n  r: \"" <> remoteDoc <> "\"\nout: \"{{r.value}}\"\n"

engineCases :: [TestTree]
engineCases =
    [ testCase "untrusted remote document is refused before any AWS call" $ do
        (mock, result) <- renderWith (importPolicy AllowRemoteImports)
        case result of
            Left (PeImportError (ImportError e)) ->
                assertBool ("expected a trust refusal, got: " <> T.unpack e) (isTrustRefusal e && remoteDoc `T.isInfixOf` e)
            Left other -> assertFailure ("expected a trust refusal, got " <> show other)
            Right r -> assertFailure ("remote document read ssm: " <> show (toValue (prValue r)))
        readIORef (mockRequests mock) >>= (@?= [])
    , testCase "remote document under a flag-built trusted prefix reads ssm:" $ do
        policy <- flagPolicy ["https://t.example.com/"]
        (mock, result) <- renderWith policy
        case result of
            Left err -> assertFailure ("expected success, got " <> show err)
            Right r -> case toValue (prValue r) of
                Object obj -> KM.lookup "out" obj @?= Just (String "db.internal.example")
                other -> assertFailure ("expected an object, got " <> show other)
        readIORef (mockRequests mock) >>= (@?= ["ssm.GetParameter.json"])
    , testCase "trust is not gained through an untrusted requester" $ do
        -- local -> untrusted https://evil.example/u.yaml -> trusted-prefix
        -- https://t.example.com/r.yaml -> ssm: (the C15 review's laundering
        -- chain): r.yaml is loaded as untrusted, so its ssm: is refused.
        policy <- flagPolicy ["https://t.example.com/"]
        mock <- newMockAws
        let dispatcher = mkFullDispatcher (mkImportConfig (Just (mockEnv mock)) policy)
            loader = stubDocLoader evilDoc evilSource (stubDocLoader remoteDoc remoteSource dispatcher)
            root = "$imports:\n  u: \"" <> evilDoc <> "\"\nout: \"{{u.v}}\"\n"
        result <- preprocessText loader "local.yaml" root
        case result of
            Left (PeImportError (ImportError e)) ->
                assertBool ("expected a trust refusal, got: " <> T.unpack e) (isTrustRefusal e && remoteDoc `T.isInfixOf` e)
            Left other -> assertFailure ("expected a trust refusal, got " <> show other)
            Right r -> assertFailure ("laundered ssm: read: " <> show (toValue (prValue r)))
        readIORef (mockRequests mock) >>= (@?= [])
    ]
  where
    evilDoc :: Text
    evilDoc = "https://evil.example/u.yaml"
    evilSource :: Text
    evilSource = "$defs:\n  own: x\n$imports:\n  t: \"" <> remoteDoc <> "\"\nv: \"{{t.value}}\"\n"
    renderWith :: ImportPolicy -> IO (MockAws, Either PreprocessError PreprocessResult)
    renderWith policy = do
        mock <- newMockAws
        let dispatcher = mkFullDispatcher (mkImportConfig (Just (mockEnv mock)) policy)
        result <- preprocessText (stubDocLoader remoteDoc remoteSource dispatcher) "local.yaml" rootSource
        pure (mock, result)
