module Test.StackArgsLoaderTest (stackArgsLoaderTests) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Map.Strict qualified
import Data.Text qualified as T
import Data.Vector qualified as V
import System.Directory (copyFile, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

import Iidy.Aws.CredentialSource (AwsSettings (..))
import Iidy.Cfn.StackArgsLoader (LoadedStackArgs (..), extractRawAwsFromAst, getInt, getStrListValidated, loadStackArgs, mergeAwsSettings, mergeSentinel, noProfileSentinel, noRoleSentinel, parseCapabilityText, parseOnFailureText, resolveEnvMaps, validateNoUnknownKeys)
import Iidy.Cfn.Types (Capability (..), CfnOperation (..), OnFailure (..), StackArgs (..), cfnOperationStr)
import Iidy.Cli (RenderArgs (..), RenderFormat (..))
import Iidy.Render (runRenderWith)
import Iidy.Types (YamlSpec (..))
import Iidy.Yaml.Ast (SrcMeta (..), YamlAst (..))
import Iidy.Yaml.Imports.Types (RemoteImports (..), importPolicy)
import Iidy.Yaml.Location (zeroPosition)
import Test.MockAws (noCredentials)
import Test.Shared (collectRawOutput, noAwsSettings, testGlobalOpts)

stackArgsLoaderTests :: [TestTree]
stackArgsLoaderTests = loaderTests <> commandsBeforeTests

loaderTests :: [TestTree]
loaderTests =
    [ testCase "load basic stack args" $ do
        result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
            Right (LoadedStackArgs sa _aws _ctx) -> do
                saStackName sa @?= "test-stack"
                saTemplate sa @?= Just "template.yaml"
                saRegion sa @?= Just "us-east-1"
    , testCase "stack args tags include environment" $ do
        result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
            Right (LoadedStackArgs sa _aws _ctx) -> do
                case saTags sa of
                    Nothing -> assertFailure "Expected tags"
                    Just tags -> do
                        assertBool "should have environment tag" $
                            any (\(k, _) -> k == "environment") (Data.Map.Strict.toList tags)
    , testCase "stack args capabilities" $ do
        result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
            Right (LoadedStackArgs sa _aws _ctx) -> do
                saCapabilities sa @?= Just [CapIAM, CapNamedIAM]
    , testCase "stack args parameters" $ do
        result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
            Right (LoadedStackArgs sa _aws _ctx) -> do
                case saParameters sa of
                    Nothing -> assertFailure "Expected parameters"
                    Just params -> do
                        Data.Map.Strict.lookup "Env" params @?= Just "dev"
                        Data.Map.Strict.lookup "Version" params @?= Just "1.0"
    , testCase "environment map resolution" $ do
        result <- loadStackArgs "test-fixtures/test-stack-args-envmap.yaml" "prod" OpUpdateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
            Right (LoadedStackArgs sa _aws _ctx) -> do
                saRegion sa @?= Just "us-west-2"
                saProfile sa @?= Just "prod-profile"
    , testCase "environment map dev" $ do
        result <- loadStackArgs "test-fixtures/test-stack-args-envmap.yaml" "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
            Right (LoadedStackArgs sa _aws _ctx) -> do
                saRegion sa @?= Just "us-east-1"
                saProfile sa @?= Just "dev-profile"
    , testCase "CLI AWS settings override argsfile" $ do
        let cliAws = AwsSettings (Just "cli-profile") (Just "eu-west-1") Nothing
        result <- loadStackArgs "test-fixtures/test-stack-args.yaml" "dev" OpCreateStack cliAws (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
            Right (LoadedStackArgs _sa aws _ctx) -> do
                awsProfile aws @?= Just "cli-profile"
                awsRegion aws @?= Just "eu-west-1"
    , testCase "missing argsfile throws" $ do
        result <-
            try @SomeException $
                loadStackArgs "nonexistent.yaml" "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left _ex -> pure ()
            Right _ -> assertFailure "Expected exception for missing file"
    , -- H-1: resolveEnvMaps error tests (matching Rust behavior)
      testCase "env map: missing env errors" $ do
        -- Region has a map but "staging" isn't in it
        let val =
                Object $
                    KM.fromList
                        [
                            ( Key.fromText "Region"
                            , Object $
                                KM.fromList
                                    [ (Key.fromText "dev", String "us-east-1")
                                    , (Key.fromText "prod", String "us-west-2")
                                    ]
                            )
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
        let val =
                Object $
                    KM.fromList
                        [
                            ( Key.fromText "Region"
                            , Object $
                                KM.fromList
                                    [ (Key.fromText "dev", Number 42)
                                    ]
                            )
                        ]
        case resolveEnvMaps val "dev" of
            Left err ->
                assertBool "error mentions must map to strings" $
                    T.isInfixOf "must map environments to strings" err
            Right _ -> assertFailure "Expected error for non-string value in env map"
    , testCase "env map: invalid type errors" $ do
        -- Region is an array, not a string or map
        let val =
                Object $
                    KM.fromList
                        [ (Key.fromText "Region", Array mempty)
                        ]
        case resolveEnvMaps val "dev" of
            Left err ->
                assertBool "error mentions must be string or environment map" $
                    T.isInfixOf "must be a string or an environment map" err
            Right _ -> assertFailure "Expected error for invalid type"
    , testCase "env map: string value passes through" $ do
        let val =
                Object $
                    KM.fromList
                        [ (Key.fromText "Region", String "us-east-1")
                        ]
        case resolveEnvMaps val "dev" of
            Left err -> assertFailure $ "Unexpected error: " <> T.unpack err
            Right (Object obj) ->
                KM.lookup (Key.fromText "Region") obj @?= Just (String "us-east-1")
            Right _ -> assertFailure "Expected Object result"
    , testCase "env map: absent field passes through" $ do
        let val =
                Object $
                    KM.fromList
                        [ (Key.fromText "StackName", String "my-stack")
                        ]
        case resolveEnvMaps val "dev" of
            Left err -> assertFailure $ "Unexpected error: " <> T.unpack err
            Right _ -> pure () -- no error for absent env map fields
    , testCase "env map: missing env via loadStackArgs" $ do
        -- Use existing envmap fixture with an environment not in the map
        result <- loadStackArgs "test-fixtures/test-stack-args-envmap.yaml" "staging" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err ->
                assertBool "error mentions environment name" $
                    T.isInfixOf "staging" err
            Right _ -> assertFailure "Expected error for missing environment in env map"
    , -- OnFailure parsing tests
      testCase "parseOnFailureText: DO_NOTHING" $
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
            Right _ -> assertFailure "Expected error for unknown OnFailure value"
    , -- Capability parsing tests
      testCase "parseCapabilityText: CAPABILITY_IAM" $
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
            Right _ -> assertFailure "Expected error for unknown Capability value"
    , -- Stack args loading with OnFailure
      testCase "load stack args with OnFailure" $ do
        result <- loadStackArgs "test-fixtures/test-stack-args-onfailure.yaml" "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
            Right (LoadedStackArgs sa _aws _ctx) ->
                saOnFailure sa @?= Just Rollback
    , -- Error on unrecognized values
      testCase "load stack args rejects unknown OnFailure" $ do
        result <- loadStackArgs "test-fixtures/test-stack-args-bad-onfailure.yaml" "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> assertBool "error mentions unrecognized" (T.isInfixOf "unrecognized" err)
            Right _ -> assertFailure "Expected error for unknown OnFailure value"
    , testCase "load stack args rejects unknown Capability" $ do
        result <- loadStackArgs "test-fixtures/test-stack-args-bad-capability.yaml" "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> assertBool "error mentions unrecognized" (T.isInfixOf "unrecognized" err)
            Right _ -> assertFailure "Expected error for unknown Capability value"
    , -- Missing StackName validation
      testCase "load stack args rejects missing StackName" $ do
        result <- loadStackArgs "test-fixtures/test-stack-args-no-name.yaml" "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> assertBool "error mentions StackName is required" (T.isInfixOf "StackName is required" err)
            Right _ -> assertFailure "Expected error for missing StackName"
    , -- getStrListValidated tests (Russell #3: no silent drops)
      testCase "getStrListValidated: all strings succeeds" $ do
        let obj =
                KM.fromList
                    [ (Key.fromText "Items", Array (V.fromList [String "a", String "b", String "c"]))
                    ]
        getStrListValidated obj "Items" @?= Right (Just ["a", "b", "c"])
    , testCase "getStrListValidated: absent key returns Nothing" $
        getStrListValidated KM.empty "Items" @?= Right Nothing
    , testCase "getStrListValidated: null returns Nothing" $ do
        let obj = KM.fromList [(Key.fromText "Items", Null)]
        getStrListValidated obj "Items" @?= Right Nothing
    , testCase "getStrListValidated: number element errors" $ do
        let obj =
                KM.fromList
                    [
                        ( Key.fromText "NotificationARNs"
                        , Array
                            ( V.fromList
                                [String "arn:aws:sns:us-east-1:123", Number 42]
                            )
                        )
                    ]
        case getStrListValidated obj "NotificationARNs" of
            Left err -> do
                assertBool "mentions field name" (T.isInfixOf "NotificationARNs" err)
                assertBool "mentions index" (T.isInfixOf "[1]" err)
                assertBool "mentions integer" (T.isInfixOf "integer" err)
            Right _ -> assertFailure "Expected error for non-string element"
    , testCase "getStrListValidated: boolean element errors" $ do
        let obj =
                KM.fromList
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
    , -- Unknown key validation tests (1D)
      testCase "validateNoUnknownKeys: typo Paramters suggests Parameters" $ do
        let obj =
                KM.fromList
                    [ (Key.fromText "StackName", String "test")
                    , (Key.fromText "Paramters", Object KM.empty)
                    ]
        case validateNoUnknownKeys obj of
            Left err -> do
                assertBool "error mentions Paramters" (T.isInfixOf "Paramters" err)
                assertBool "error suggests Parameters" (T.isInfixOf "did you mean Parameters?" err)
            Right _ -> assertFailure "Expected error for unknown key Paramters"
    , testCase "validateNoUnknownKeys: far-off key has no suggestion" $ do
        let obj =
                KM.fromList
                    [ (Key.fromText "StackName", String "test")
                    , (Key.fromText "FooBarBazQux", String "whatever")
                    ]
        case validateNoUnknownKeys obj of
            Left err -> do
                assertBool "error mentions FooBarBazQux" (T.isInfixOf "FooBarBazQux" err)
                assertBool "no suggestion" (not (T.isInfixOf "did you mean" err))
            Right _ -> assertFailure "Expected error for unknown key FooBarBazQux"
    , testCase "validateNoUnknownKeys: all valid keys pass" $ do
        let obj =
                KM.fromList
                    [ (Key.fromText "StackName", String "test")
                    , (Key.fromText "Template", String "t.yaml")
                    , (Key.fromText "Parameters", Object KM.empty)
                    , (Key.fromText "Tags", Object KM.empty)
                    ]
        validateNoUnknownKeys obj @?= Right ()
    , testCase "validateNoUnknownKeys: $envValues is not flagged" $ do
        let obj =
                KM.fromList
                    [ (Key.fromText "StackName", String "test")
                    , (Key.fromText "$envValues", Object KM.empty)
                    ]
        validateNoUnknownKeys obj @?= Right ()
    , testCase "loadStackArgs: unknown key fixture errors with suggestion" $ do
        result <- loadStackArgs "test-fixtures/test-stack-args-unknown-key.yaml" "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> do
                assertBool "error mentions Paramters" (T.isInfixOf "Paramters" err)
                assertBool "error suggests Parameters" (T.isInfixOf "Parameters" err)
            Right _ -> assertFailure "Expected error for unknown key in fixture"
    , -- Sentinel value tests (no-profile / no-role)
      testCase "no-profile sentinel clears argsfile profile" $ do
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
    , -- getInt validation tests (no silent rounding of floats)
      testCase "getInt: integer value succeeds" $ do
        let obj = KM.fromList [(Key.fromText "TimeoutInMinutes", Number 30)]
        getInt obj "TimeoutInMinutes" @?= Right (Just 30)
    , testCase "getInt: float value errors" $ do
        let obj = KM.fromList [(Key.fromText "TimeoutInMinutes", Number 30.5)]
        case getInt obj "TimeoutInMinutes" of
            Left err -> do
                assertBool "mentions float" (T.isInfixOf "float" err)
                assertBool "mentions 30.5" (T.isInfixOf "30.5" err)
            Right _ -> assertFailure "Expected error for float TimeoutInMinutes"
    , testCase "getInt: absent key returns Nothing" $
        getInt KM.empty "TimeoutInMinutes" @?= Right Nothing
    , testCase "getInt: null returns Nothing" $ do
        let obj = KM.fromList [(Key.fromText "TimeoutInMinutes", Null)]
        getInt obj "TimeoutInMinutes" @?= Right Nothing
    , testCase "loadStackArgs rejects float TimeoutInMinutes" $ do
        result <- loadStackArgs "test-fixtures/test-stack-args-float-timeout.yaml" "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
        case result of
            Left err -> assertBool "error mentions float" (T.isInfixOf "float" err)
            Right _ -> assertFailure "Expected error for float TimeoutInMinutes"
    , -- extractRawAwsFromAst tests (pre-preprocessing bootstrap)
      testCase "extractRawAwsFromAst: plain string fields" $ do
        let ast =
                AstMapping
                    [ (AstPlainString "StackName" m, AstPlainString "test" m)
                    , (AstPlainString "Region" m, AstPlainString "us-east-1" m)
                    , (AstPlainString "Profile" m, AstPlainString "my-profile" m)
                    , (AstPlainString "AssumeRoleARN" m, AstPlainString "arn:aws:iam::123:role/Foo" m)
                    ]
                    m
            result = extractRawAwsFromAst ast "dev"
        awsRegion result @?= Just "us-east-1"
        awsProfile result @?= Just "my-profile"
        awsAssumeRoleArn result @?= Just "arn:aws:iam::123:role/Foo"
    , testCase "extractRawAwsFromAst: environment map resolution" $ do
        let ast =
                AstMapping
                    [ (AstPlainString "StackName" m, AstPlainString "test" m)
                    ,
                        ( AstPlainString "Region" m
                        , AstMapping
                            [ (AstPlainString "dev" m, AstPlainString "us-east-1" m)
                            , (AstPlainString "prod" m, AstPlainString "us-west-2" m)
                            ]
                            m
                        )
                    ,
                        ( AstPlainString "Profile" m
                        , AstMapping
                            [ (AstPlainString "dev" m, AstPlainString "dev-profile" m)
                            , (AstPlainString "prod" m, AstPlainString "prod-profile" m)
                            ]
                            m
                        )
                    ]
                    m
        let dev = extractRawAwsFromAst ast "dev"
        awsRegion dev @?= Just "us-east-1"
        awsProfile dev @?= Just "dev-profile"
        let prod = extractRawAwsFromAst ast "prod"
        awsRegion prod @?= Just "us-west-2"
        awsProfile prod @?= Just "prod-profile"
    , testCase "extractRawAwsFromAst: missing fields return Nothing" $ do
        let ast =
                AstMapping
                    [ (AstPlainString "StackName" m, AstPlainString "test" m)
                    ]
                    m
            result = extractRawAwsFromAst ast "dev"
        awsRegion result @?= Nothing
        awsProfile result @?= Nothing
        awsAssumeRoleArn result @?= Nothing
    , testCase "extractRawAwsFromAst: null fields return Nothing" $ do
        let ast =
                AstMapping
                    [ (AstPlainString "Region" m, AstNull m)
                    , (AstPlainString "Profile" m, AstNull m)
                    ]
                    m
            result = extractRawAwsFromAst ast "dev"
        awsRegion result @?= Nothing
        awsProfile result @?= Nothing
    , testCase "extractRawAwsFromAst: non-mapping AST returns empty" $ do
        let result = extractRawAwsFromAst (AstPlainString "not-a-mapping" m) "dev"
        awsRegion result @?= Nothing
        awsProfile result @?= Nothing
        awsAssumeRoleArn result @?= Nothing
    , testCase "extractRawAwsFromAst: env map missing env returns Nothing" $ do
        let ast =
                AstMapping
                    [
                        ( AstPlainString "Region" m
                        , AstMapping
                            [ (AstPlainString "dev" m, AstPlainString "us-east-1" m)
                            ]
                            m
                        )
                    ]
                    m
            result = extractRawAwsFromAst ast "staging"
        awsRegion result @?= Nothing
    , testCase "a repeated key at the top level is a parse error" $
        loadText "StackName: s\nTemplate: t.yaml\nTags:\n  a: x\nTags:\n  b: y\n"
            >>= assertDuplicate "Tags" "line 5 column 1"
    , testCase "a repeated key nested in a mapping is a parse error" $
        loadText "StackName: s\nTemplate: t.yaml\nParameters:\n  P: x\n  P: y\n"
            >>= assertDuplicate "P" "line 5 column 3"
    , testCase "a and \"a\" are the same key" $
        loadText "StackName: s\nTemplate: t.yaml\nTags:\n  a: x\n  \"a\": y\n"
            >>= assertDuplicate "a" "line 5 column 3"
    , testCase "1 and \"1\" are different keys" $
        loadText "StackName: s\nTemplate: t.yaml\nTags:\n  1: x\n  \"1\": y\n" >>= either (assertFailure . ("expected success, got: " <>) . T.unpack) (const (pure ()))
    ]
  where
    loadText :: BS.ByteString -> IO (Either T.Text LoadedStackArgs)
    loadText text = withSystemTempDirectory "stack-args-dup" $ \dir -> do
        let fp = dir </> "stack-args.yaml"
        BS.writeFile fp text
        loadStackArgs fp "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
    assertDuplicate :: T.Text -> T.Text -> Either T.Text LoadedStackArgs -> IO ()
    assertDuplicate key pos r = case r of
        Right _ -> assertFailure "expected a duplicate key parse error"
        Left err -> do
            assertBool ("Parse error: " <> T.unpack err) ("Parse error" `T.isInfixOf` err)
            assertBool
                ("message: " <> T.unpack err)
                (("duplicate entry with key \"" <> key <> "\" at " <> pos) `T.isInfixOf` err)
    m :: SrcMeta
    m = SrcMeta "" zeroPosition zeroPosition

{- | CommandsBefore runs for the operations Rust and iidy-js run it for
(Rust @should_process_commands_before@, stack_args.rs:483-490), in the
argsfile's directory, and is left alone for every other operation and for
render. The run itself is tested in "Test.CommandsBeforeLoadTest".
-}
commandsBeforeTests :: [TestTree]
commandsBeforeTests =
    [ testCase ("CommandsBefore runs for " <> T.unpack (cfnOperationStr op)) $
        withCommandsBeforeCopy $ \dir argsfile -> do
            result <- loadStackArgs argsfile "dev" op noAwsSettings (importPolicy AllowRemoteImports) Nothing
            case result of
                Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
                Right (LoadedStackArgs sa _aws _ctx) ->
                    saCommandsBefore sa @?= Just ["touch commands-before-ran.marker"]
            ranInArgsDir <- doesFileExist (dir </> marker)
            assertBool "the command ran in the argsfile directory" ranInArgsDir
    | op <- [OpCreateStack, OpUpdateStack, OpCreateChangeset, OpCreateOrUpdate]
    ]
        <> [ testCase "an empty CommandsBefore list loads for create-stack" $
                withSystemTempDirectory "iidy-commands-before" $ \dir -> do
                    let argsfile = dir </> "stack-args.yaml"
                    writeFile argsfile "StackName: test-stack\nTemplate: template.yaml\nRegion: us-east-1\nCommandsBefore: []\n"
                    result <- loadStackArgs argsfile "dev" OpCreateStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
                    case result of
                        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
                        Right (LoadedStackArgs sa _aws _ctx) -> saCommandsBefore sa @?= Just []
           , testCase "CommandsBefore is accepted and not run for delete-stack" $
                withCommandsBeforeCopy $ \dir argsfile -> do
                    result <- loadStackArgs argsfile "dev" OpDeleteStack noAwsSettings (importPolicy AllowRemoteImports) Nothing
                    case result of
                        Left err -> assertFailure $ "loadStackArgs failed: " <> T.unpack err
                        Right (LoadedStackArgs sa _aws _ctx) ->
                            saCommandsBefore sa @?= Just ["touch commands-before-ran.marker"]
                    assertNoMarker dir
           , testCase "a stack-args file with CommandsBefore renders" $
                withCommandsBeforeCopy $ \dir argsfile -> do
                    (emit, readOut) <- collectRawOutput
                    rc <- runRenderWith noCredentials emit (renderStdout (T.pack argsfile)) (testGlobalOpts False)
                    rc @?= 0
                    out <- T.concat <$> readOut
                    assertBool ("render output keeps CommandsBefore: " <> T.unpack out) ("CommandsBefore" `T.isInfixOf` out)
                    assertNoMarker dir
           ]
  where
    marker :: FilePath
    marker = "commands-before-ran.marker"
    -- The fixture's command would create the marker in the argsfile's
    -- directory (where Rust and iidy-js run it) or in the current one.
    assertNoMarker :: FilePath -> Assertion
    assertNoMarker dir = do
        inArgsDir <- doesFileExist (dir </> marker)
        inCwd <- doesFileExist marker
        assertBool "a CommandsBefore command ran" (not (inArgsDir || inCwd))
    renderStdout :: T.Text -> RenderArgs
    renderStdout path =
        RenderArgs
            { raTemplate = path
            , raOutfile = "-"
            , raFormat = RenderYaml
            , raQuery = Nothing
            , raOverwrite = False
            , raYamlSpec = YamlAuto
            }

-- | Run with a copy of the CommandsBefore fixture in a fresh directory.
withCommandsBeforeCopy :: (FilePath -> FilePath -> IO a) -> IO a
withCommandsBeforeCopy act = withSystemTempDirectory "iidy-commands-before" $ \dir -> do
    let argsfile = dir </> "stack-args.yaml"
    copyFile "test-fixtures/test-stack-args-commands-before.yaml" argsfile
    act dir argsfile
