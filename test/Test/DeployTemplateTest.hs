{- | The deploy request builders with template approval on: they send a
presigned URL for the approved object instead of the local body, and
refuse an unapproved template before any CloudFormation call. Mock AWS
only.
-}
module Test.DeployTemplateTest (deployTemplateTests) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Amazonka.CloudFormation qualified as CF
import Amazonka.CloudFormation.CreateChangeSet qualified as CCS
import Amazonka.CloudFormation.CreateStack qualified as CS
import Amazonka.CloudFormation.UpdateStack qualified as US
import Options.Applicative (ParserResult (..), execParserPure, prefs)

import Iidy.Aws.CredentialSource (CredentialSource (..), CredentialSourceStack (..), ProfileInfo (..), ProfileSource (..))
import Iidy.Cfn.Context (CfnContext (..))
import Iidy.Cfn.RequestBuilder (buildCreateChangeSetRequest, buildCreateStackRequest, buildUpdateStackRequest)
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..))
import Iidy.Cli (ApprovalCommands (..), ApprovalRequestArgs (..), AwsOpts (..), Cli (..), Commands (..), GlobalOpts (..))
import Iidy.Cli.Parser (cliParserInfo)
import Test.ApprovalFixtures (approvalArgs, notApproved, notApprovedIn, simpleApprovedKey, simpleTemplate, withSizedTemplate)
import Test.MockAws
import Test.MockCfnContext (MockCfn (..), newMockCfnContext)

-- | A builder under test: its name and how to run it to the template fields.
data Builder = Builder
    { builderName :: String
    , runBuilder :: CfnContext -> StackArgs -> IO (Either Text (Maybe Text, Maybe Text))
    -- ^ (TemplateBody, TemplateURL) of the built request
    }

builders :: [Builder]
builders =
    [ Builder "create-stack" $ \ctx sa ->
        fmap (\(r, _) -> (CS.templateBody r, CS.templateURL r))
            <$> buildCreateStackRequest ctx sa True argsfile
    , Builder "update-stack" $ \ctx sa ->
        fmap (\(r, _) -> (US.templateBody r, US.templateURL r))
            <$> buildUpdateStackRequest ctx sa True argsfile
    , Builder "create-changeset" $ \ctx sa ->
        fmap (\(r, _) -> (CCS.templateBody r, CCS.templateURL r))
            <$> buildCreateChangeSetRequest ctx sa "cs" CF.ChangeSetType_UPDATE argsfile
    ]

deployTemplateTests :: [TestTree]
deployTemplateTests =
    [ testGroup (builderName b) (perBuilderTests b) | b <- builders
    ]
        <> [ testGroup "create-stack only" createOnlyTests
           , testCase "the suggested request command parses with the deploy's settings" suggestionParses
           ]

perBuilderTests :: Builder -> [TestTree]
perBuilderTests b =
    [ testCase "approved: presigned URL for the approved object, no body" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" simpleApprovedKey) (mockStatus 200)
        result <- run b mock (stackArgs (Just simpleTemplate))
        case result of
            Right (Nothing, Just url) -> do
                assertBool
                    ("URL is the approved object: " <> show url)
                    (("https://approvals.s3.us-east-1.amazonaws.com/" <> simpleApprovedKey <> "?") `T.isPrefixOf` url)
                assertBool ("URL is signed: " <> show url) ("X-Amz-Signature=" `T.isInfixOf` url)
                assertBool ("URL expires in 900s: " <> show url) ("X-Amz-Expires=900" `T.isInfixOf` url)
            other -> assertFailure ("expected a URL and no body, got " <> show other)
        mockOperations mock >>= (@?= ["GetBucketLocation", "HeadObject"])
    , testCase "not approved (404): refused with the request command" $ do
        mock <- newMockAws
        result <- run b mock (stackArgs (Just simpleTemplate))
        result @?= Left notApproved
        mockOperations mock >>= (@?= ["GetBucketLocation", "HeadObject"])
    , testCase "access denied (403): its own message" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" simpleApprovedKey) (mockStatus 403)
        result <- run b mock (stackArgs (Just simpleTemplate))
        result
            @?= Left
                ( "Access denied (403) checking s3://approvals/"
                    <> simpleApprovedKey
                    <> ": the current credentials cannot read the template approval bucket"
                    <> " (S3 also answers 403 for a missing object when s3:ListBucket is not granted)"
                )
    , testCase "other HeadObject failure: names the region" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" simpleApprovedKey) (mockStatus 500)
        result <- run b mock (stackArgs (Just simpleTemplate))
        let prefix = "Failed to check s3://approvals/" <> simpleApprovedKey <> " in region us-east-1: "
        assertBool ("names the region: " <> show result) (either (T.isPrefixOf prefix) (const False) result)
    , testCase "URL Template: refused before any AWS call" $ do
        mock <- newMockAws
        result <- run b mock (stackArgs (Just "https://example.com/t.yaml"))
        result
            @?= Left
                ( "Template must be a local file when ApprovedTemplateLocation is set, "
                    <> "not a URL (https://example.com/t.yaml): template approval hashes the rendered local template"
                )
        mockOperations mock >>= (@?= [])
    , testCase "no Template: refused before any AWS call" $ do
        mock <- newMockAws
        result <- run b mock (stackArgs Nothing)
        result
            @?= Left
                ( "Template is required in stack-args.yaml when ApprovedTemplateLocation is set: "
                    <> "template approval hashes the rendered local template"
                )
        mockOperations mock >>= (@?= [])
    , testCase "approval off: local body as before, no AWS call" $ do
        mock <- newMockAws
        result <- run b mock (stackArgs (Just simpleTemplate)){saApprovedTemplateLocation = Nothing}
        case result of
            Right (Just body, Nothing) ->
                assertBool ("body is the template: " <> show body) ("AWSTemplateFormatVersion" `T.isInfixOf` body)
            other -> assertFailure ("expected a body and no URL, got " <> show other)
        mockOperations mock >>= (@?= [])
    ]

createOnlyTests :: [TestTree]
createOnlyTests =
    [ testCase "bucket in eu-west-1, stack in us-east-1: URL host and scope are eu-west-1" $ do
        mock <- newMockAws
        mockRespond mock (OnOperation "s3" "GetBucketLocation") (bucketLocationReply "eu-west-1")
        mockRespond mock (OnObject "HeadObject" "approvals" simpleApprovedKey) (mockStatus 200)
        result <- run createBuilder mock (stackArgs (Just simpleTemplate))
        case result of
            Right (Nothing, Just url) -> do
                assertBool
                    ("host is eu-west-1: " <> show url)
                    ("https://approvals.s3.eu-west-1.amazonaws.com/" `T.isPrefixOf` url)
                assertBool ("scope is eu-west-1: " <> show url) ("%2Feu-west-1%2Fs3%2F" `T.isInfixOf` url)
            other -> assertFailure ("expected a URL, got " <> show other)
        regions <- map s3HostRegion <$> mockRequestLog mock
        regions @?= [Just "us-east-1", Just "eu-west-1"]
    , testCase "profile from --profile: the suggested command carries it" $ do
        mock <- newMockAws
        mcfn <- newMockCfnContext mock OpCreateStack "prod"
        let ctx =
                (mcContext mcfn)
                    { cfnCredentialSources =
                        CredentialSourceStack [ProfileCredential (ProfileInfo "ops" ProfileCliFlag Nothing)]
                    }
        result <- runBuilder createBuilder ctx (stackArgs (Just simpleTemplate))
        result @?= Left (notApprovedIn "prod" " --profile ops")
    , testCase "999999-byte template: accepted on the approval path" $
        withSizedTemplate 999999 $ \path -> do
            mock <- newMockAws
            mockRespond mock (OnOperation "s3" "HeadObject") (mockStatus 200)
            result <- run createBuilder mock (stackArgs (Just path))
            case result of
                Right (Nothing, Just _) -> pure ()
                other -> assertFailure ("expected a URL, got " <> show (fmap fst other))
    , testCase "1000000-byte template: refused without suggesting S3" $
        withSizedTemplate 1000000 $ \path -> do
            mock <- newMockAws
            result <- run createBuilder mock (stackArgs (Just path))
            result @?= Left "Template body exceeds maximum size of 999999 bytes (got 1000000 bytes)."
            mockOperations mock >>= (@?= [])
    ]

{- | The refusal's suggested command, parsed by the real CLI parser, names
the argsfile, the region, the environment and the profile of the deploy.
-}
suggestionParses :: IO ()
suggestionParses = do
    let message = notApprovedIn "prod" " --profile ops"
        commandLine = T.strip (T.takeWhile (/= '\n') (T.drop 1 (T.dropWhile (/= '\n') message)))
    case T.words commandLine of
        "iidy-hs" : rest -> case execParserPure (prefs mempty) cliParserInfo (map T.unpack rest) of
            Success cli -> do
                aoRegion (cliAwsOpts cli) @?= Just "us-east-1"
                aoProfile (cliAwsOpts cli) @?= Just "ops"
                goEnvironment (cliGlobalOpts cli) @?= "prod"
                case cliCommand cli of
                    CmdTemplateApproval (ApprovalRequest args) -> araArgsfile args @?= "stack-args.yaml"
                    other -> assertFailure ("expected template-approval request, got " <> show other)
            _failure -> assertFailure ("suggested command does not parse: " <> show commandLine)
        other -> assertFailure ("expected an iidy-hs command, got " <> show other)

-- | The create-stack builder.
createBuilder :: Builder
createBuilder = case builders of
    b : _ -> b
    [] -> Builder "none" (\_ _ -> pure (Left "no builder"))

-- | Run a builder over a mock context for environment @test@.
run :: Builder -> MockAws -> StackArgs -> IO (Either Text (Maybe Text, Maybe Text))
run b mock sa = do
    mcfn <- newMockCfnContext mock OpCreateStack "test"
    runBuilder b (mcContext mcfn) sa

-- | Stack args with approval on for this Template.
stackArgs :: Maybe Text -> StackArgs
stackArgs template = (approvalArgs template){saStackName = "approved-stack"}

-- | The argsfile the builders are given.
argsfile :: Maybe FilePath
argsfile = Just "stack-args.yaml"
