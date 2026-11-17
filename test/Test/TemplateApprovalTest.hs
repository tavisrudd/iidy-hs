{- | Tests for @template-approval request@ and @review@ through the mock AWS
env: how they treat S3 errors.
-}
module Test.TemplateApprovalTest (templateApprovalTests) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Iidy.Cfn.Operations.TemplateApproval (templateApprovalRequest, templateApprovalReview)
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..), emptyStackArgs)
import Test.MockAws
import Test.MockCfnContext (MockCfn (..), newMockCfnContext)

templateApprovalTests :: [TestTree]
templateApprovalTests =
    [ testGroup "HeadObject errors" headErrorTests
    ]

headErrorTests :: [TestTree]
headErrorTests =
    [ testCase "request: HeadObject 403 on the approved key fails with no PutObject" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" approvedKey) (mockStatus 403)
        result <- runRequest mock
        result @?= Left (accessDenied approvedKey)
        operations mock >>= (@?= ["HeadObject"])
    , testCase "request: HeadObject 500 fails naming the region" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" approvedKey) (mockStatus 500)
        result <- runRequest mock
        let prefix = "Failed to check s3://approvals/" <> approvedKey <> " in region us-east-1: "
        assertBool ("failure names the region: " <> show result) (either (T.isPrefixOf prefix) (const False) result)
        operations mock >>= (@?= ["HeadObject"])
    , testCase "review: HeadObject 403 on the pending key is access denied" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" pendingKey) (mockStatus 403)
        result <- runReview mock
        result @?= Left (accessDenied pendingKey)
    , testCase "review: HeadObject 403 on the approved key fails before any download" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" pendingKey) (mockStatus 200)
        mockRespond mock (OnObject "HeadObject" "approvals" approvedKey) (mockStatus 403)
        result <- runReview mock
        result @?= Left (accessDenied approvedKey)
        operations mock >>= (@?= ["HeadObject", "HeadObject"])
    , testCase "review: a missing pending object is still 'not found'" $ do
        mock <- newMockAws
        result <- runReview mock
        result @?= Left ("Pending template not found at s3://approvals/" <> pendingKey)
    ]

-- | The access-denied message for an object in the @approvals@ bucket.
accessDenied :: Text -> Text
accessDenied key =
    "Access denied (403) checking s3://approvals/"
        <> key
        <> ": the current credentials cannot read the template approval bucket"

-- | Run the request for the fixture template under @s3://approvals/app@.
runRequest :: MockAws -> IO (Either Text Int)
runRequest mock = do
    mcfn <- newMockCfnContext mock OpTemplateApprovalRequest "test"
    templateApprovalRequest (mcContext mcfn) approvalArgs False Nothing

-- | Run the review of the fixture's pending object.
runReview :: MockAws -> IO (Either Text Int)
runReview mock = do
    mcfn <- newMockCfnContext mock OpTemplateApprovalReview "test"
    templateApprovalReview (mcContext mcfn) ("s3://approvals/" <> pendingKey) 3

-- | The S3 operations the mock received, in order.
operations :: MockAws -> IO [Text]
operations mock = map (maybe "?" callOperation . reqCall) <$> mockRequestLog mock

-- | Stack args with approval on for the fixture template.
approvalArgs :: StackArgs
approvalArgs =
    emptyStackArgs
        { saTemplate = Just "test-fixtures/template-loader/simple.yaml"
        , saApprovedTemplateLocation = Just "s3://approvals/app"
        }

-- | The fixture's approved key under @s3://approvals/app@.
approvedKey :: Text
approvedKey = "app/4e4e06e485ce06aabba82ff4af435f0e58425b8ea1ecdfee2f52709ea663c4fa.yaml"

-- | The fixture's pending key.
pendingKey :: Text
pendingKey = approvedKey <> ".pending"
