{- | End to end through the commands that reach the deploy builders after
@DescribeStacks@: create-or-update (direct and @--changeset@) and
@update-stack --changeset@, and estimate-cost. With approval on, an unapproved template is
refused before any mutating CloudFormation call, and an approved one is
sent as the presigned URL. Mock AWS only: the stack exists (the
@DescribeStacks@ fixture), and the mutating call is answered with an error
so the command stops after it.
-}
module Test.DeployCommandsTest (deployCommandsTests) where

import Control.Exception (SomeException, try)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Iidy.Cfn.Context (CfnContext)
import Iidy.Cfn.Operations.CreateOrUpdate (createOrUpdate)
import Iidy.Cfn.Operations.EstimateCost (estimateCost)
import Iidy.Cfn.Operations.UpdateStack (updateStackWithChangeset)
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..))
import Test.ApprovalFixtures (approvalArgs, notApproved, simpleApprovedKey, simpleTemplate, validationError)
import Test.MockAws
import Test.MockCfnContext (MockCfn (..), newMockCfnContext)

-- | A command under test and the mutating CloudFormation call it makes.
data Command = Command
    { commandName :: String
    , mutatingCall :: Text
    , runCommand :: CfnContext -> StackArgs -> IO (Either Text Int)
    }

commands :: [Command]
commands =
    [ Command "create-or-update" "UpdateStack" $ \ctx sa ->
        createOrUpdate ctx sa False True argsfile
    , Command "create-or-update --changeset" "CreateChangeSet" $ \ctx sa ->
        createOrUpdate ctx sa True True argsfile
    , Command "update-stack --changeset" "CreateChangeSet" $ \ctx sa ->
        updateStackWithChangeset ctx sa True argsfile
    ]

deployCommandsTests :: [TestTree]
deployCommandsTests =
    [testGroup (commandName c) (commandTests c) | c <- commands]
        <> [testGroup "estimate-cost" estimateCostTests]

estimateCostTests :: [TestTree]
estimateCostTests =
    [ testCase "approved: EstimateTemplateCost gets the presigned URL, no body" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" simpleApprovedKey) (mockStatus 200)
        result <- runEstimate mock (approvalArgs (Just simpleTemplate))
        result @?= Right (Right 0)
        bodies <- estimateBodies mock
        case bodies of
            [body] -> do
                assertBool ("TemplateURL is signed: " <> show body) (presignedApprovedUrl body)
                assertBool ("no TemplateBody: " <> show body) (not ("TemplateBody=" `BS.isInfixOf` body))
            other -> assertBool ("expected one EstimateTemplateCost, got " <> show (length other)) False
    , testCase "unapproved: refused, no EstimateTemplateCost call" $ do
        mock <- newMockAws
        result <- runEstimate mock (approvalArgs (Just simpleTemplate))
        result @?= Right (Left notApproved)
        mockOperations mock >>= (@?= ["GetBucketLocation", "HeadObject"])
    , testCase "approval off: the local body, no S3 call" $ do
        mock <- newMockAws
        result <- runEstimate mock (approvalArgs (Just simpleTemplate)){saApprovedTemplateLocation = Nothing}
        result @?= Right (Right 0)
        mockOperations mock >>= (@?= ["EstimateTemplateCost"])
        bodies <- estimateBodies mock
        assertBool ("TemplateBody sent: " <> show bodies) (all ("TemplateBody=" `BS.isInfixOf`) bodies)
    ]

-- | Run estimate-cost with a successful EstimateTemplateCost reply.
runEstimate :: MockAws -> StackArgs -> IO (Either String (Either Text Int))
runEstimate mock sa = do
    mockRespond mock (OnOperation "cloudformation" "EstimateTemplateCost") (MockResponse 200 estimateReply)
    mcfn <- newMockCfnContext mock OpEstimateCost "test"
    result <- try @SomeException (estimateCost (mcContext mcfn) sa argsfile)
    pure (either (Left . show) Right result)

-- | The bodies of the EstimateTemplateCost requests sent.
estimateBodies :: MockAws -> IO [BS.ByteString]
estimateBodies mock = do
    logged <- mockRequestLog mock
    pure [reqBody r | r <- logged, fmap callOperation (reqCall r) == Just "EstimateTemplateCost"]

-- | A successful EstimateTemplateCost reply.
estimateReply :: BS.ByteString
estimateReply =
    "<EstimateTemplateCostResponse xmlns=\"http://cloudformation.amazonaws.com/doc/2010-05-15/\">"
        <> "<EstimateTemplateCostResult><Url>https://calculator.example/estimate</Url></EstimateTemplateCostResult>"
        <> "<ResponseMetadata><RequestId>r</RequestId></ResponseMetadata></EstimateTemplateCostResponse>"

-- | A form body whose TemplateURL is the fixture's approved object, signed.
presignedApprovedUrl :: BS.ByteString -> Bool
presignedApprovedUrl body =
    "TemplateURL=https%3A%2F%2Fapprovals.s3.us-east-1.amazonaws.com%2Fapp%2F" `BS.isInfixOf` body
        && "X-Amz-Signature" `BS.isInfixOf` body

commandTests :: Command -> [TestTree]
commandTests c =
    [ testCase "unapproved: refused, no mutating CloudFormation call" $ do
        mock <- newMockAws
        result <- runWith c mock
        result @?= Just notApproved
        ops <- mockOperations mock
        assertBool ("no " <> show (mutatingCall c) <> ": " <> show ops) (mutatingCall c `notElem` ops)
        assertBool ("DescribeStacks first, as iidy-js: " <> show ops) (take 1 ops == ["DescribeStacks"])
    , testCase "approved: the mutating call sends the presigned URL, no body" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" simpleApprovedKey) (mockStatus 200)
        _ <- runWith c mock
        logged <- mockRequestLog mock
        let sent =
                [ reqBody r
                | r <- logged
                , fmap callOperation (reqCall r) == Just (mutatingCall c)
                ]
        case sent of
            [body] -> do
                assertBool ("TemplateURL is the approved object, signed: " <> show body) (presignedApprovedUrl body)
                assertBool ("no TemplateBody: " <> show body) (not ("TemplateBody=" `BS.isInfixOf` body))
            other -> assertBool ("expected one " <> show (mutatingCall c) <> ", got " <> show (length other)) False
    ]

{- | Run the command for the fixture with approval on; the error text, if
it failed with one (an exception from the mocked error reply counts as no
text).
-}
runWith :: Command -> MockAws -> IO (Maybe Text)
runWith c mock = do
    mockRespond mock (OnOperation "cloudformation" (mutatingCall c)) (MockResponse 400 validationError)
    mcfn <- newMockCfnContext mock OpCreateOrUpdate "test"
    let sa = (approvalArgs (Just simpleTemplate)){saStackName = "network-stack"}
    result <- try @SomeException (runCommand c (mcContext mcfn) sa)
    pure $ case result of
        Right (Left err) -> Just err
        _ -> Nothing

-- | The argsfile the commands are given.
argsfile :: Maybe FilePath
argsfile = Just "stack-args.yaml"
