{- | Tests for the AWS environment that stack-args imports run under
('loadStackArgsBootstrapped'), against the in-process mock AWS.
-}
module Test.StackArgsBootstrapTest (stackArgsBootstrapTests) where

import Amazonka qualified
import Amazonka.SSM.GetParameter qualified as GP
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Aws.CredentialSource (AwsSettings (..))
import Iidy.Cfn.CommandsBefore (defaultCommandsBeforeSettings)
import Iidy.Cfn.StackArgsBootstrap (
    checkImportSettings,
    importSettingsMismatch,
    loadAndCheckWith,
    loadRecordingImportSettings,
    loadStackArgsBootstrapped,
 )
import Iidy.Cfn.StackArgsLoader (CredentialField (..), LoadedStackArgs (..), RawField (..), readRawField)
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..))
import Iidy.Yaml.Imports.Types (RemoteImports (..), importPolicy)
import Iidy.Yaml.Parser (parseYaml)
import Test.MockAws (MockAws (..), mockAccessKey, mockSecretKey, mockSessionToken, newMockAws, newRefusingMockAws, recordingEnvFactory)
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
    , testCase "a duplicate top-level Profile key is refused at parse time, before any import" $
        loadWithMock noAwsSettings "probe-duplicate-key.yaml" >>= expectDuplicateKey "Profile" "line 10 column 1"
    , testCase "a templated Profile key with an ssm: import is refused" $
        loadWithMock noAwsSettings "probe-templated-key.yaml" >>= expectRefused "Profile" "--profile"
    , testCase "a partly templated Profile key with an ssm: import is refused" $
        loadWithMock noAwsSettings "probe-partly-templated-key.yaml" >>= expectRefused "Profile" "--profile"
    , testCase "a tagged Profile key with an ssm: import is refused" $
        loadWithMock noAwsSettings "probe-tagged-key.yaml" >>= expectRefused "Profile" "--profile"
    , testCase "a duplicate environment-map entry is refused at parse time, before any import" $
        loadWithMock noAwsSettings "probe-envmap-duplicate-entry.yaml" >>= expectDuplicateKey "dev" "line 11 column 3"
    , testCase "a templated environment-map key with an ssm: import is refused" $
        loadWithMock noAwsSettings "probe-envmap-templated-key.yaml" >>= expectRefused "Profile" "--profile"
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
        rawField "Region: \"{{r}}\"" CredRegion @?= RawComputed "Region is the handlebars template {{r}}"
        rawField "Profile: !$ prof" CredProfile @?= RawComputed "Profile is a preprocessing tag"
        rawField "Profile: {dev: !$ prof}" CredProfile @?= RawComputed "Profile (environment entry 'dev') is a preprocessing tag"
        rawField "Profile: {prod: p}" CredProfile
            @?= RawComputed "Profile is an environment map with no entry for environment dev"
    , testCase "raw reading: duplicate and non-plain keys are not literal" $ do
        rawField "Profile: a\nProfile: b" CredProfile @?= RawComputed "Profile appears more than once"
        rawField "Region: r\n\"{{k}}\": x" CredRegion
            @?= RawComputed "the stack-args mapping has a key that is not a plain string, which could set Region"
        rawField "Profile: {dev: a, \"{{e}}\": b}" CredProfile
            @?= RawComputed "the environment map for Profile has a key that is not a plain string"
    , testCase "backstop: matching import and final settings pass" $
        importSettingsMismatch "f.yaml" literalSettings literalSettings @?= Nothing
    , testCase "backstop: a Profile that differs from the import's is refused" $ do
        err <- expectJust (importSettingsMismatch "f.yaml" literalSettings literalSettings{awsProfile = Just "evil-profile"})
        mapM_ (assertMentions err) ["Profile", "literal-profile", "evil-profile", "--profile", "plain strings"]
    , testCase "backstop: a Region set only after preprocessing is refused" $ do
        err <- expectJust (importSettingsMismatch "f.yaml" literalSettings{awsRegion = Nothing} literalSettings)
        mapM_ (assertMentions err) ["Region", "not set", "eu-west-1", "--region"]
    , testCase "seam: the load records the settings an ssm: import ran with" $ do
        (result, recorded) <- loadRecording "literal-ssm.yaml"
        _ <- expectRight result
        recorded @?= Just literalSettings
    , testCase "seam: a load with no AWS import records no settings" $ do
        (result, recorded) <- loadRecording "computed-region-no-aws.yaml"
        _ <- expectRight result
        recorded @?= Nothing
    , testCase "seam: import settings that differ from the final ones refuse the load" $ do
        -- The plain-only check keeps a real load's recorded and final
        -- settings equal, so stand in for an import that ran elsewhere.
        mock <- newMockAws
        (factory, _) <- recordingEnvFactory mock
        let elsewhere = literalSettings{awsProfile = Just "import-profile"}
            tampered argsfile env op cli policy = do
                (result, _) <- loadRecordingImportSettings defaultCommandsBeforeSettings factory argsfile env op cli policy
                pure (result, Just elsewhere)
        result <- loadAndCheckWith tampered (fixturePath "literal-ssm.yaml") "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports)
        err <- expectLeft result
        Just err @?= importSettingsMismatch (T.pack (fixturePath "literal-ssm.yaml")) elsewhere literalSettings
    , testCase "seam: the comparison passes a failed load through" $
        checkImportSettings "f.yaml" (Just literalSettings) (Left "parse failed") @?= Left "parse failed"
    , testCase "a factory failure with an ssm: import reports its cause" $ do
        result <-
            loadStackArgsBootstrapped
                defaultCommandsBeforeSettings
                (\_ -> ioError (userError "mock: no such profile literal-profile"))
                (fixturePath "literal-ssm.yaml")
                "dev"
                OpCreateStack
                noAwsSettings
                (importPolicy AllowRemoteImports)
        err <- expectLeft result
        assertBool ("reports the cause: " <> T.unpack err) ("mock: no such profile literal-profile" `T.isInfixOf` err)
        assertBool ("names the import: " <> T.unpack err) ("ssm:/app/db-host" `T.isInfixOf` err)
    , testCase "a transport failure while building the env names no credential" $ do
        refusing <- newRefusingMockAws
        let factory _ = Amazonka.runResourceT (Amazonka.send refusing (GP.newGetParameter "/x")) >> pure refusing
        result <-
            loadStackArgsBootstrapped
                defaultCommandsBeforeSettings
                factory
                (fixturePath "literal-ssm.yaml")
                "dev"
                OpCreateStack
                noAwsSettings
                (importPolicy AllowRemoteImports)
        err <- expectLeft result
        mapM_
            (\bad -> assertBool (T.unpack bad <> " leaked in: " <> T.unpack err) (not (bad `T.isInfixOf` err)))
            [mockSessionToken, mockAccessKey, mockSecretKey, "Signature=", "X-Amz-Security-Token"]
        assertBool ("names the host: " <> T.unpack err) ("ssm.us-east-1.amazonaws.com" `T.isInfixOf` err)
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
    result <- loadStackArgsBootstrapped defaultCommandsBeforeSettings factory (fixturePath fixture) "dev" OpCreateStack cliAws (importPolicy AllowRemoteImports)
    BootstrapRun result <$> askedFor <*> readIORef (mockRequests mock)

-- | Load a fixture through the recording step alone, with a mock factory.
loadRecording :: FilePath -> IO (Either Text LoadedStackArgs, Maybe AwsSettings)
loadRecording fixture = do
    mock <- newMockAws
    (factory, _) <- recordingEnvFactory mock
    loadRecordingImportSettings defaultCommandsBeforeSettings factory (fixturePath fixture) "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports)

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
    mapM_ (assertMentions err) [key, flag, "plain string"]
    bsAsked run @?= []
    bsServed run @?= []

{- | The file was refused at parse time for a repeated key (before the
bootstrap scan or any import ran): no factory call and no AWS request.
-}
expectDuplicateKey :: Text -> Text -> BootstrapRun -> IO ()
expectDuplicateKey key pos run = do
    err <- expectLeft (bsResult run)
    mapM_ (assertMentions err) ["Parse error", "duplicate entry with key \"" <> key <> "\" at " <> pos]
    bsAsked run @?= []
    bsServed run @?= []

-- | Read one credential field of a YAML snippet for environment @dev@.
rawField :: String -> CredentialField -> RawField
rawField yaml field = case parseYaml (BLC.pack yaml) "snippet.yaml" of
    Left _ -> RawComputed "unparseable test snippet"
    Right ast -> readRawField ast "dev" field

assertMentions :: Text -> Text -> IO ()
assertMentions err t = assertBool ("error mentions " <> T.unpack t <> ": " <> T.unpack err) (t `T.isInfixOf` err)

expectJust :: Maybe Text -> IO Text
expectJust = maybe (assertFailure "expected a refusal") pure

-- | The settings of @literal-ssm.yaml@.
literalSettings :: AwsSettings
literalSettings = AwsSettings (Just "literal-profile") (Just "eu-west-1") Nothing
