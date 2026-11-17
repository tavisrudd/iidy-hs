{- | Tests for the AWS environment that stack-args imports run under
('loadStackArgsBootstrapped'), against the in-process mock AWS.
-}
module Test.StackArgsBootstrapTest (stackArgsBootstrapTests) where

import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Aws.CredentialSource (AwsSettings (..))
import Iidy.Cfn.StackArgsBootstrap (loadStackArgsBootstrapped)
import Iidy.Cfn.StackArgsLoader (CredentialField (..), LoadedStackArgs (..), RawField (..), readRawField)
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..))
import Iidy.Yaml.Imports.Types (RemoteImports (..))
import Iidy.Yaml.Parser (parseYaml)
import Test.MockAws (MockAws (..), newMockAws, recordingEnvFactory)
import Test.Shared (noAwsSettings)

stackArgsBootstrapTests :: [TestTree]
stackArgsBootstrapTests =
    [ testCase "literal Profile and Region with an ssm: import load under those literals" $ do
        run <- loadWithMock noAwsSettings "literal-ssm.yaml"
        loaded <- expectRight (bsResult run)
        bsAsked run @?= [AwsSettings (Just "literal-profile") (Just "eu-west-1") Nothing]
        bsServed run @?= ["ssm.GetParameter.json"]
        saParameters (lsaStackArgs loaded) @?= Just (Map.fromList [("DbHost", "db.internal.example")])
    , testCase "computed Profile from an import with an ssm: import is refused" $ do
        run <- loadWithMock noAwsSettings "computed-profile-import.yaml"
        expectRefused "Profile" "--profile" run
    , testCase "computed Profile from a $defs reference with an ssm: import is refused" $ do
        run <- loadWithMock noAwsSettings "computed-profile-defs.yaml"
        expectRefused "Profile" "--profile" run
    , testCase "templated Region with an ssm: import is refused" $ do
        run <- loadWithMock noAwsSettings "templated-region-ssm.yaml"
        expectRefused "Region" "--region" run
        err <- expectLeft (bsResult run)
        assertBool ("names the template: " <> T.unpack err) ("{{r}}" `T.isInfixOf` err)
    , testCase "computed Region with no AWS import loads as before" $ do
        run <- loadWithMock noAwsSettings "computed-region-no-aws.yaml"
        loaded <- expectRight (bsResult run)
        saRegion (lsaStackArgs loaded) @?= Just "eu-west-1"
        awsRegion (lsaMergedAws loaded) @?= Just "eu-west-1"
        bsAsked run @?= []
    , testCase "a CLI --profile equal to the computed Profile passes" $ do
        let cli = noAwsSettings{awsProfile = Just "computed-profile"}
        run <- loadWithMock cli "computed-profile-defs.yaml"
        loaded <- expectRight (bsResult run)
        bsAsked run @?= [cli]
        bsServed run @?= ["ssm.GetParameter.json"]
        awsProfile (lsaMergedAws loaded) @?= Just "computed-profile"
    , testCase "raw reading: plain string and environment-map entry are literal" $ do
        rawField "Region: eu-west-1" CredRegion @?= RawLiteral "eu-west-1"
        rawField "Profile: {dev: dev-profile, prod: prod-profile}" CredProfile @?= RawLiteral "dev-profile"
        rawField "StackName: x" CredAssumeRoleArn @?= RawAbsent
    , testCase "raw reading: templates, tags and missing map entries are not literal" $ do
        rawField "Region: \"{{r}}\"" CredRegion @?= RawComputed "the handlebars template {{r}}"
        rawField "Profile: !$ prof" CredProfile @?= RawComputed "a preprocessing tag"
        rawField "Profile: {dev: !$ prof}" CredProfile @?= RawComputed "a preprocessing tag"
        rawField "Profile: {prod: p}" CredProfile
            @?= RawComputed "an environment map with no entry for environment dev"
    , testCase "a factory failure with an ssm: import reports its cause" $ do
        result <-
            loadStackArgsBootstrapped
                (\_ -> ioError (userError "mock: no such profile literal-profile"))
                (fixturePath "literal-ssm.yaml")
                "dev"
                OpCreateStack
                noAwsSettings
                AllowRemoteImports
        err <- expectLeft result
        assertBool ("reports the cause: " <> T.unpack err) ("mock: no such profile literal-profile" `T.isInfixOf` err)
        assertBool ("names the import: " <> T.unpack err) ("ssm:/app/db-host" `T.isInfixOf` err)
    ]

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | What one load did: its result, the factory calls, the mock requests.
data BootstrapRun = BootstrapRun
    { bsResult :: !(Either Text LoadedStackArgs)
    , bsAsked :: ![AwsSettings]
    , bsServed :: ![FilePath]
    }

-- | Load a fixture with the given CLI settings and a recording mock factory.
loadWithMock :: AwsSettings -> FilePath -> IO BootstrapRun
loadWithMock cliAws fixture = do
    mock <- newMockAws
    (factory, askedFor) <- recordingEnvFactory mock
    result <- loadStackArgsBootstrapped factory (fixturePath fixture) "dev" OpCreateStack cliAws AllowRemoteImports
    BootstrapRun result <$> askedFor <*> readIORef (mockRequests mock)

fixturePath :: FilePath -> FilePath
fixturePath name = "test-fixtures/stack-args-bootstrap/" <> name

expectRight :: Either Text a -> IO a
expectRight = either (assertFailure . ("expected the load to succeed: " <>) . T.unpack) pure

expectLeft :: Either Text a -> IO Text
expectLeft = either pure (const (assertFailure "expected the load to be refused"))

{- | The load was refused before any AWS call, and the error names the field
and the command-line option that sets it.
-}
expectRefused :: Text -> Text -> BootstrapRun -> IO ()
expectRefused key flag run = do
    err <- expectLeft (bsResult run)
    let mentions t = assertBool ("error mentions " <> T.unpack t <> ": " <> T.unpack err) (t `T.isInfixOf` err)
    mentions key
    mentions flag
    mentions "plain string"
    bsAsked run @?= []
    bsServed run @?= []

-- | Read one credential field of a YAML snippet for environment @dev@.
rawField :: String -> CredentialField -> RawField
rawField yaml field = case parseYaml (BLC.pack yaml) "snippet.yaml" of
    Left _ -> RawComputed "unparseable test snippet"
    Right ast -> readRawField ast "dev" field
