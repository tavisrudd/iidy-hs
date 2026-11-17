{- | End to end through the commands that reach the deploy builders after
@DescribeStacks@: create-or-update (direct and @--changeset@) and
@update-stack --changeset@. With approval on, an unapproved template is
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
deployCommandsTests = [testGroup (commandName c) (commandTests c) | c <- commands]

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
                assertBool
                    ("TemplateURL is the approved object, signed: " <> show body)
                    ( "TemplateURL=https%3A%2F%2Fapprovals.s3.us-east-1.amazonaws.com%2Fapp%2F" `BS.isInfixOf` body
                        && "X-Amz-Signature" `BS.isInfixOf` body
                    )
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
