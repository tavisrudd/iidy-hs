{- | Tests for @template-approval request@ and @review@ through the mock AWS
env: how they treat S3 errors and the approval-path size limit.
-}
module Test.TemplateApprovalTest (templateApprovalTests) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Iidy.Cfn.Operations.TemplateApproval (templateApprovalRequest, templateApprovalReview)
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..), emptyStackArgs)
import Test.MockAws
import Test.MockCfnContext (MockCfn (..), newMockCfnContext)

templateApprovalTests :: [TestTree]
templateApprovalTests =
    [ testGroup "HeadObject errors" headErrorTests
    , testGroup "1 MB approval-path limit" sizeLimitTests
    ]

sizeLimitTests :: [TestTree]
sizeLimitTests =
    [ testCase "request: a 999999-byte template is accepted" $
        withSizedTemplate 999999 $ \path -> do
            mock <- newMockAws
            result <- runRequestFor mock path
            result @?= Right 0
            operations mock >>= (@?= ["HeadObject", "PutObject"])
    , testCase "request: a 1000000-byte template is refused without suggesting S3" $
        withSizedTemplate 1000000 $ \path -> do
            mock <- newMockAws
            result <- runRequestFor mock path
            result @?= Left "Template body exceeds maximum size of 999999 bytes (got 1000000 bytes)."
            operations mock >>= (@?= [])
    ]

{- | Run an action with a local template file of exactly this many bytes
(a YAML document padded with a comment).
-}
withSizedTemplate :: Int -> (Text -> IO a) -> IO a
withSizedTemplate size action =
    withSystemTempDirectory "iidy-approval-size" $ \dir -> do
        let header = "AWSTemplateFormatVersion: '2010-09-09'\nResources: {}\n# "
            padding = BC.replicate (size - BS.length header - 1) 'x'
            path = dir </> "big.yaml"
        BS.writeFile path (header <> padding <> "\n")
        action (T.pack path)

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
runRequest mock = runRequestFor mock "test-fixtures/template-loader/simple.yaml"

-- | Run the request for a template under @s3://approvals/app@.
runRequestFor :: MockAws -> Text -> IO (Either Text Int)
runRequestFor mock template = do
    mcfn <- newMockCfnContext mock OpTemplateApprovalRequest "test"
    templateApprovalRequest (mcContext mcfn) (approvalArgs template) False Nothing

-- | Run the review of the fixture's pending object.
runReview :: MockAws -> IO (Either Text Int)
runReview mock = do
    mcfn <- newMockCfnContext mock OpTemplateApprovalReview "test"
    templateApprovalReview (mcContext mcfn) ("s3://approvals/" <> pendingKey) 3

-- | The S3 operations the mock received, in order.
operations :: MockAws -> IO [Text]
operations mock = map (maybe "?" callOperation . reqCall) <$> mockRequestLog mock

-- | Stack args with approval on for a template.
approvalArgs :: Text -> StackArgs
approvalArgs template =
    emptyStackArgs
        { saTemplate = Just template
        , saApprovedTemplateLocation = Just "s3://approvals/app"
        }

-- | The fixture's approved key under @s3://approvals/app@.
approvedKey :: Text
approvedKey = "app/4e4e06e485ce06aabba82ff4af435f0e58425b8ea1ecdfee2f52709ea663c4fa.yaml"

-- | The fixture's pending key.
pendingKey :: Text
pendingKey = approvedKey <> ".pending"
