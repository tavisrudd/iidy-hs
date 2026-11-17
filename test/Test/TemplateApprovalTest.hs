{- | Tests for @template-approval request@ and @review@ through the mock AWS
env: S3 errors, the approval-path size limit, the pending upload and
the lint step.
-}
module Test.TemplateApprovalTest (templateApprovalTests) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Iidy.Cfn.Operations.TemplateApproval (templateApprovalRequest, templateApprovalReview)
import Iidy.Cfn.Types (CfnOperation (..))
import Iidy.Output.Types (OutputData (..), TemplateValidation (..))
import Test.ApprovalFixtures (approvalArgs, simpleApprovedKey, simplePendingKey, simpleTemplate, validationError)
import Test.MockAws
import Test.MockCfnContext (MockCfn (..), mockCfnOutputs, newMockCfnContext)

templateApprovalTests :: [TestTree]
templateApprovalTests =
    [ testGroup "HeadObject errors" headErrorTests
    , testGroup "1 MB approval-path limit" sizeLimitTests
    , testCase "request: the pending upload carries bucket-owner-full-control" $ do
        mock <- newMockAws
        result <- runRequest mock
        result @?= Right 0
        puts <- filter ((== Just "PutObject") . fmap callOperation . reqCall) <$> mockRequestLog mock
        map (lookup "x-amz-acl" . reqHeaders) puts @?= [Just "bucket-owner-full-control"]
    , testGroup "request lint" lintTests
    ]

lintTests :: [TestTree]
lintTests =
    [ testCase "lint on, valid: validates the local body, then uploads" $ do
        mock <- newMockAws
        mockRespond mock validateOperation (MockResponse 200 validResponse)
        (result, outputs) <- runLint mock True simpleTemplate
        result @?= Right 0
        operations mock >>= (@?= ["HeadObject", "ValidateTemplate", "PutObject"])
        validations outputs @?= [TemplateValidation True [] []]
        validatedBodies mock >>= (@?= [True])
    , testCase "lint on, invalid: emits the errors, exits 1, no upload" $ do
        mock <- newMockAws
        mockRespond mock validateOperation (MockResponse 400 validationError)
        (result, outputs) <- runLint mock True simpleTemplate
        result @?= Right 1
        operations mock >>= (@?= ["HeadObject", "ValidateTemplate"])
        case validations outputs of
            [tv] ->
                assertBool
                    ("errors carry the message: " <> show (tvErrors tv))
                    (any ("Template format error" `T.isInfixOf`) (tvErrors tv))
            other -> assertBool ("expected one validation, got " <> show other) False
    , testCase "lint on, over the inline limit in bytes: skipped with a warning, uploads" $
        -- 30000 two-byte characters: under the limit in characters, over it in bytes
        withTemplateBytes (templateHeader <> TE.encodeUtf8 (T.replicate 30000 "\233") <> "\n") $ \path -> do
            mock <- newMockAws
            (result, outputs) <- runLint mock True path
            result @?= Right 0
            operations mock >>= (@?= ["HeadObject", "PutObject"])
            validations outputs
                @?= [ TemplateValidation
                        True
                        []
                        ["Template exceeds 51200 bytes; skipping CFN validation (will be validated on deploy)"]
                    ]
    , testCase "lint off: no ValidateTemplate call" $ do
        mock <- newMockAws
        (result, outputs) <- runLint mock False simpleTemplate
        result @?= Right 0
        operations mock >>= (@?= ["HeadObject", "PutObject"])
        validations outputs @?= []
    , testCase "lint on, already approved: no ValidateTemplate call" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" simpleApprovedKey) (mockStatus 200)
        (result, _) <- runLint mock True simpleTemplate
        result @?= Right 0
        operations mock >>= (@?= ["HeadObject"])
    ]

-- | Run the request with lint on or off; the result and the outputs.
runLint :: MockAws -> Bool -> Text -> IO (Either Text Int, [OutputData])
runLint mock lint template = do
    mcfn <- newMockCfnContext mock OpTemplateApprovalRequest "test"
    result <- templateApprovalRequest (mcContext mcfn) (approvalArgs (Just template)) lint Nothing
    outputs <- mockCfnOutputs mcfn
    pure (result, outputs)

-- | The template validations among the outputs.
validations :: [OutputData] -> [TemplateValidation]
validations outputs = [tv | OdTemplateValidation tv <- outputs]

-- | For each ValidateTemplate call, whether it sent the fixture's body.
validatedBodies :: MockAws -> IO [Bool]
validatedBodies mock = do
    logged <- mockRequestLog mock
    pure
        [ "TemplateBody=AWSTemplateFormatVersion" `BS.isInfixOf` reqBody r
        | r <- logged
        , fmap callOperation (reqCall r) == Just "ValidateTemplate"
        ]

-- | The CloudFormation ValidateTemplate operation.
validateOperation :: MockMatch
validateOperation = OnOperation "cloudformation" "ValidateTemplate"

-- | A successful ValidateTemplate reply.
validResponse :: BS.ByteString
validResponse =
    "<ValidateTemplateResponse xmlns=\"http://cloudformation.amazonaws.com/doc/2010-05-15/\">"
        <> "<ValidateTemplateResult/><ResponseMetadata><RequestId>r</RequestId></ResponseMetadata>"
        <> "</ValidateTemplateResponse>"

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
withSizedTemplate size =
    withTemplateBytes
        (templateHeader <> BC.replicate (size - BS.length templateHeader - 1) 'x' <> "\n")

-- | Run an action with a local template file holding these bytes.
withTemplateBytes :: BS.ByteString -> (Text -> IO a) -> IO a
withTemplateBytes bytes action =
    withSystemTempDirectory "iidy-approval-template" $ \dir -> do
        let path = dir </> "big.yaml"
        BS.writeFile path bytes
        action (T.pack path)

-- | A minimal template ending in an open comment, for padding.
templateHeader :: BS.ByteString
templateHeader = "AWSTemplateFormatVersion: '2010-09-09'\nResources: {}\n# "

headErrorTests :: [TestTree]
headErrorTests =
    [ testCase "request: HeadObject 403 on the approved key fails with no PutObject" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" simpleApprovedKey) (mockStatus 403)
        result <- runRequest mock
        result @?= Left (accessDenied simpleApprovedKey)
        operations mock >>= (@?= ["HeadObject"])
    , testCase "request: HeadObject 500 fails naming the region" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" simpleApprovedKey) (mockStatus 500)
        result <- runRequest mock
        let prefix = "Failed to check s3://approvals/" <> simpleApprovedKey <> " in region us-east-1: "
        assertBool ("failure names the region: " <> show result) (either (T.isPrefixOf prefix) (const False) result)
        operations mock >>= (@?= ["HeadObject"])
    , testCase "review: HeadObject 403 on the pending key is access denied" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" simplePendingKey) (mockStatus 403)
        result <- runReview mock
        result @?= Left (accessDenied simplePendingKey)
    , testCase "review: HeadObject 403 on the approved key fails before any download" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" simplePendingKey) (mockStatus 200)
        mockRespond mock (OnObject "HeadObject" "approvals" simpleApprovedKey) (mockStatus 403)
        result <- runReview mock
        result @?= Left (accessDenied simpleApprovedKey)
        operations mock >>= (@?= ["HeadObject", "HeadObject"])
    , testCase "review: a missing pending object is still 'not found'" $ do
        mock <- newMockAws
        result <- runReview mock
        result @?= Left ("Pending template not found at s3://approvals/" <> simplePendingKey)
    ]

-- | The access-denied message for an object in the @approvals@ bucket.
accessDenied :: Text -> Text
accessDenied key =
    "Access denied (403) checking s3://approvals/"
        <> key
        <> ": the current credentials cannot read the template approval bucket"
        <> " (S3 also answers 403 for a missing object when s3:ListBucket is not granted)"

-- | Run the request for the fixture template under @s3://approvals/app@.
runRequest :: MockAws -> IO (Either Text Int)
runRequest mock = runRequestFor mock simpleTemplate

-- | Run the request for a template under @s3://approvals/app@.
runRequestFor :: MockAws -> Text -> IO (Either Text Int)
runRequestFor mock template = do
    mcfn <- newMockCfnContext mock OpTemplateApprovalRequest "test"
    templateApprovalRequest (mcContext mcfn) (approvalArgs (Just template)) False Nothing

-- | Run the review of the fixture's pending object.
runReview :: MockAws -> IO (Either Text Int)
runReview mock = do
    mcfn <- newMockCfnContext mock OpTemplateApprovalReview "test"
    templateApprovalReview (mcContext mcfn) ("s3://approvals/" <> simplePendingKey) 3

-- | The S3 operations the mock received, in order.
operations :: MockAws -> IO [Text]
operations mock = map (maybe "?" callOperation . reqCall) <$> mockRequestLog mock
