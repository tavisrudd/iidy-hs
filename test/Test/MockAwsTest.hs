{- | Self-tests for the mock AWS env ('Test.MockAws') and the mock
'CfnContext' ('Test.MockCfnContext'): S3 REST and query-protocol
operations are recognised, served as configured, and logged raw.
-}
module Test.MockAwsTest (mockAwsTests) where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Amazonka qualified

import Iidy.Cfn.Operations.LintTemplate (lintTemplate)
import Iidy.Cfn.Operations.TemplateApproval (templateApprovalRequest, templateApprovalReview)
import Iidy.Cfn.Types (CfnOperation (..), StackArgs (..), emptyStackArgs)
import Iidy.Output.Types (ApprovalResult (..), ApprovalStatus (..), OutputData (..), TemplateValidation (..))
import Test.MockAws
import Test.MockCfnContext (MockCfn (..), mockCfnOutputs, newMockCfnContext)

mockAwsTests :: [TestTree]
mockAwsTests =
    [ testCase "HeadObject: 404 by default" $ do
        mock <- newMockAws
        mcfn <- newMockCfnContext mock OpTemplateApprovalReview "test"
        result <- templateApprovalReview (mcContext mcfn) pendingUrl 3
        result @?= Left ("Pending template not found at " <> pendingUrl)
        calls <- map reqCall <$> mockRequestLog mock
        calls @?= [Just (s3Call "HeadObject" "app/t.yaml.pending")]
    , testCase "HeadObject: 200 as configured per object" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" "app/t.yaml.pending") (mockStatus 200)
        mockRespond mock (OnObject "HeadObject" "approvals" "app/t.yaml") (mockStatus 200)
        mcfn <- newMockCfnContext mock OpTemplateApprovalReview "test"
        result <- templateApprovalReview (mcContext mcfn) pendingUrl 3
        result @?= Right 0
        outputs <- mockCfnOutputs mcfn
        case outputs of
            [OdApprovalStatus st] -> do
                apsAlreadyApproved st @?= True
                apsApprovedLocation st @?= Just "s3://approvals/app/t.yaml"
            other -> assertFailure ("unexpected outputs: " <> show other)
        responses <- map reqMethod <$> mockRequestLog mock
        responses @?= ["HEAD", "HEAD"]
    , testCase "object override wins over operation override; GetObject bodies per object" $ do
        mock <- newMockAws
        mockRespond mock (OnOperation "s3" "HeadObject") (mockStatus 200)
        mockRespond mock (OnObject "HeadObject" "approvals" "app/t.yaml") (mockStatus 404)
        mockRespond mock (OnObject "GetObject" "approvals" "app/t.yaml.pending") (MockResponse 200 "same: body\n")
        mockRespond mock (OnObject "GetObject" "approvals" "app/latest") (MockResponse 200 "same: body\n")
        mcfn <- newMockCfnContext mock OpTemplateApprovalReview "test"
        result <- templateApprovalReview (mcContext mcfn) pendingUrl 3
        result @?= Right 0
        outputs <- mockCfnOutputs mcfn
        assertBool
            ("identical bodies give an approval result: " <> show outputs)
            (any isApproved outputs)
        calls <- map reqCall <$> mockRequestLog mock
        calls
            @?= map
                Just
                [ s3Call "HeadObject" "app/t.yaml.pending"
                , s3Call "HeadObject" "app/t.yaml"
                , s3Call "GetObject" "app/t.yaml.pending"
                , s3Call "GetObject" "app/latest"
                ]
    , testCase "PutObject in eu-west-1: raw log keeps host, method and body" $ do
        mock <- newMockAwsIn (Amazonka.Region' "eu-west-1")
        mcfn <- newMockCfnContext mock OpTemplateApprovalRequest "test"
        let sa =
                emptyStackArgs
                    { saTemplate = Just "test-fixtures/template-loader/simple.yaml"
                    , saApprovedTemplateLocation = Just "s3://approvals/app"
                    }
        result <- templateApprovalRequest (mcContext mcfn) sa False Nothing
        result @?= Right 0
        logged <- mockRequestLog mock
        case logged of
            [hd, put] -> do
                reqMethod hd @?= "HEAD"
                reqMethod put @?= "PUT"
                fmap callOperation (reqCall put) @?= Just "PutObject"
                assertBool "pending key" (maybe False (T.isSuffixOf ".pending") (reqCall put >>= callKey))
                assertBool ("host names eu-west-1: " <> show (reqHost put)) ("eu-west-1" `BS.isInfixOf` reqHost put)
                assertBool
                    ("body is the rendered template: " <> show (reqBody put))
                    ("AWSTemplateFormatVersion" `BS.isInfixOf` reqBody put)
            other -> assertFailure ("expected HEAD then PUT, got " <> show (map reqMethod other))
    , testGroup "S3 request recognition" recognitionTests
    , testCase "query protocol: operation override serves error XML" $ do
        mock <- newMockAws
        mockRespond
            mock
            (OnOperation "cloudformation" "ValidateTemplate")
            (MockResponse 400 validationError)
        mcfn <- newMockCfnContext mock OpLintTemplate "test"
        let sa = emptyStackArgs{saTemplate = Just "test-fixtures/template-loader/simple.yaml"}
        result <- lintTemplate (mcContext mcfn) sa Nothing
        result @?= Right 1
        outputs <- mockCfnOutputs mcfn
        case outputs of
            [OdTemplateValidation tv] ->
                assertBool
                    ("error carries the mock message: " <> show (tvErrors tv))
                    (any ("Template format error" `T.isInfixOf`) (tvErrors tv))
            other -> assertFailure ("unexpected outputs: " <> show other)
    ]

recognitionTests :: [TestTree]
recognitionTests =
    [ testCase "virtual host: bucket before the endpoint" $
        recognised "HEAD" "approvals.s3.amazonaws.com" "/app/t.yaml"
            @?= Just (MockCall "s3" "HeadObject" (Just "approvals") (Just "app/t.yaml"))
    , testCase "virtual host: bucket named s3-..." $
        recognised "HEAD" "s3-approvals.s3.amazonaws.com" "/app/t.yaml"
            @?= Just (MockCall "s3" "HeadObject" (Just "s3-approvals") (Just "app/t.yaml"))
    , testCase "virtual host: dotted bucket with an s3 label" $
        recognised "GET" "my.s3.bkt.s3.eu-west-1.amazonaws.com" "/t.yaml"
            @?= Just (MockCall "s3" "GetObject" (Just "my.s3.bkt") (Just "t.yaml"))
    , testCase "path style: bucket is the first path segment" $
        recognised "PUT" "s3.eu-west-1.amazonaws.com" "/approvals/app/t%20x.yaml"
            @?= Just (MockCall "s3" "PutObject" (Just "approvals") (Just "app/t x.yaml"))
    , testCase "virtual host: GET /?location is GetBucketLocation" $
        recognised "GET" "approvals.s3.amazonaws.com" "/?location"
            @?= Just (MockCall "s3" "GetBucketLocation" (Just "approvals") Nothing)
    , testCase "path style: GET /bucket?location= is GetBucketLocation" $
        recognised "GET" "s3.amazonaws.com" "/approvals?location="
            @?= Just (MockCall "s3" "GetBucketLocation" (Just "approvals") Nothing)
    ]

-- | The call the mock recognises in a request with no body.
recognised :: BS.ByteString -> BS.ByteString -> BS.ByteString -> Maybe MockCall
recognised method host path =
    parseRequest (method <> " " <> path <> " HTTP/1.1\r\nHost: " <> host <> "\r\n\r\n") >>= reqCall

-- | The pending object the review tests use.
pendingUrl :: T.Text
pendingUrl = "s3://approvals/app/t.yaml.pending"

-- | An S3 call on the @approvals@ bucket.
s3Call :: T.Text -> T.Text -> MockCall
s3Call op key = MockCall "s3" op (Just "approvals") (Just key)

-- | An approval result that approved the template.
isApproved :: OutputData -> Bool
isApproved = \case
    OdApprovalResult r -> arApproved r
    _ -> False

-- | A CloudFormation query-protocol error body.
validationError :: BS.ByteString
validationError =
    "<ErrorResponse><Error><Type>Sender</Type><Code>ValidationError</Code>"
        <> "<Message>Template format error</Message></Error></ErrorResponse>"
