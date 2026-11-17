{- | Tests for the approved-template location ('Iidy.Cfn.ApprovedTemplate')
and its use by @template-approval request@, through the mock AWS env.
-}
module Test.ApprovedTemplateTest (approvedTemplateTests) where

import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import Iidy.Cfn.ApprovedTemplate (ApprovedTemplate (..), approvedKeyFromPending, approvedTemplateFor, latestKeyFromPending, pendingKeyFor)
import Iidy.Cfn.Operations.TemplateApproval (templateApprovalRequest)
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..), emptyStackArgs)
import Test.MockAws
import Test.MockCfnContext (MockCfn (..), newMockCfnContext)

approvedTemplateTests :: [TestTree]
approvedTemplateTests =
    [ testGroup "request refusals before any S3 call" requestRefusalTests
    , testGroup "approved location" locationTests
    , testGroup "pending keys" pendingKeyTests
    ]

locationTests :: [TestTree]
locationTests =
    [ testCase "no ApprovedTemplateLocation: Nothing, no AWS call" $ do
        mock <- newMockAws
        mcfn <- newMockCfnContext mock OpCreateStack "test"
        let sa = emptyStackArgs{saTemplate = Just simpleTemplate}
        result <- approvedTemplateFor (mcContext mcfn) sa Nothing
        result @?= Right Nothing
        logged <- mockRequestLog mock
        logged @?= []
    , testCase "key is the base path, the SHA256 of the body and the extension" $ do
        mock <- newMockAws
        mcfn <- newMockCfnContext mock OpCreateStack "test"
        result <- approvedTemplateFor (mcContext mcfn) (approvalArgs (Just simpleTemplate)) Nothing
        case result of
            Right (Just at) -> do
                atBucket at @?= "approvals"
                atKey at @?= simpleApprovedKey
            other -> assertFailure ("expected an approved template, got " <> show other)
    , testCase "request HEADs the approved key and uploads the pending key" $ do
        mock <- newMockAws
        mcfn <- newMockCfnContext mock OpTemplateApprovalRequest "test"
        result <- templateApprovalRequest (mcContext mcfn) (approvalArgs (Just simpleTemplate)) False Nothing
        result @?= Right 0
        calls <- map reqCall <$> mockRequestLog mock
        calls
            @?= [ Just (MockCall "s3" "HeadObject" (Just "approvals") (Just simpleApprovedKey))
                , Just (MockCall "s3" "PutObject" (Just "approvals") (Just (simpleApprovedKey <> ".pending")))
                ]
    ]

pendingKeyTests :: [TestTree]
pendingKeyTests =
    [ testCase "approved key round-trips through the pending key" $
        approvedKeyFromPending (pendingKeyFor simpleApprovedKey) @?= Right simpleApprovedKey
    , testCase "pending key appends .pending" $
        pendingKeyFor "app/abc.yaml" @?= "app/abc.yaml.pending"
    , testCase "latest key sits in the pending key's directory" $
        latestKeyFromPending "app/env/abc.yaml.pending" @?= "app/env/latest"
    , testCase "latest key for a pending key with no directory" $
        latestKeyFromPending "abc.yaml.pending" @?= "latest"
    , testCase "a key without .pending is rejected" $
        approvedKeyFromPending "app/abc.yaml" @?= Left "URL must end with .pending suffix"
    ]

-- | A local template fixture.
simpleTemplate :: Text
simpleTemplate = "test-fixtures/template-loader/simple.yaml"

-- | Its approved key under @s3://approvals/app@ (SHA256 of the file).
simpleApprovedKey :: Text
simpleApprovedKey = "app/4e4e06e485ce06aabba82ff4af435f0e58425b8ea1ecdfee2f52709ea663c4fa.yaml"

requestRefusalTests :: [TestTree]
requestRefusalTests =
    [ testCase "s3:// Template is refused" $
        refusedBeforeS3
            (Just "s3://bucket/t.yaml")
            ( "Template must be a local file when ApprovedTemplateLocation is set, "
                <> "not a URL (s3://bucket/t.yaml): template approval hashes the rendered local template"
            )
    , testCase "https:// Template is refused" $
        refusedBeforeS3
            (Just "https://example.com/t.yaml")
            ( "Template must be a local file when ApprovedTemplateLocation is set, "
                <> "not a URL (https://example.com/t.yaml): template approval hashes the rendered local template"
            )
    , testCase "missing Template is refused" $
        refusedBeforeS3
            Nothing
            ( "Template is required in stack-args.yaml when ApprovedTemplateLocation is set: "
                <> "template approval hashes the rendered local template"
            )
    ]

-- | The request fails with this message and makes no AWS call.
refusedBeforeS3 :: Maybe Text -> Text -> IO ()
refusedBeforeS3 template expected = do
    mock <- newMockAws
    mcfn <- newMockCfnContext mock OpTemplateApprovalRequest "test"
    result <- templateApprovalRequest (mcContext mcfn) (approvalArgs template) False Nothing
    result @?= Left expected
    logged <- mockRequestLog mock
    logged @?= []

-- | Stack args with approval on and the given Template.
approvalArgs :: Maybe Text -> StackArgs
approvalArgs template =
    emptyStackArgs
        { saTemplate = template
        , saApprovedTemplateLocation = Just "s3://approvals/app"
        }
