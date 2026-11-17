{- | The approval bucket's region: request and review send their S3 calls to
the bucket's own region (from @GetBucketLocation@, asked of us-east-1),
falling back to the stack's region when that call fails.
-}
module Test.ApprovalRegionTest (approvalRegionTests) where

import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Amazonka qualified

import Iidy.Cfn.Operations.TemplateApproval (templateApprovalRequest, templateApprovalReview)
import Iidy.Cfn.RequestBuilder (buildCreateStackRequest)
import Iidy.Cfn.Types (CfnOperation (..))
import Test.ApprovalFixtures (approvalArgs, simplePendingKey, simpleTemplate)
import Test.MockAws
import Test.MockCfnContext (MockCfn (..), newMockCfnContext)

approvalRegionTests :: [TestTree]
approvalRegionTests =
    [ testGroup "request" requestTests
    , testGroup "review" reviewTests
    , testGroup "failed lookup named in later failures" lookupNoteTests
    ]

lookupNoteTests :: [TestTree]
lookupNoteTests =
    [ testCase "request: wrong fallback region (HeadObject 301) names the failed lookup" $ do
        mock <- mockWithLocation "eu-west-1" Nothing
        mockRespond mock (OnOperation "s3" "HeadObject") (mockStatus 301)
        result <- runRequest mock
        assertLookupNote result
    , testCase "review: access denied after a failed lookup names it" $ do
        mock <- mockWithLocation "eu-west-1" Nothing
        mockRespond mock (OnOperation "s3" "HeadObject") (mockStatus 403)
        mcfn <- newMockCfnContext mock OpTemplateApprovalReview "test"
        result <- templateApprovalReview (mcContext mcfn) ("s3://approvals/" <> simplePendingKey) 3
        assertLookupNote result
    , testCase "deploy builder: HeadObject failure after a failed lookup names it" $ do
        mock <- mockWithLocation "eu-west-1" Nothing
        mockRespond mock (OnOperation "s3" "HeadObject") (mockStatus 301)
        mcfn <- newMockCfnContext mock OpCreateStack "test"
        result <- buildCreateStackRequest (mcContext mcfn) (approvalArgs (Just simpleTemplate)) True Nothing
        assertLookupNote (void result)
    , testCase "a successful lookup adds no note" $ do
        mock <- mockWithLocation "eu-west-1" (Just "eu-west-1")
        mockRespond mock (OnOperation "s3" "HeadObject") (mockStatus 301)
        result <- runRequest mock
        assertBool ("no lookup note: " <> show result) (either (not . T.isInfixOf "region lookup") (const False) result)
    ]

-- | The failure names the region and ends with the failed lookup's note.
assertLookupNote :: (Show a) => Either Text a -> IO ()
assertLookupNote result = case result of
    Left err -> do
        assertBool ("names the lookup failure: " <> show err) ("(bucket region lookup failed: " `T.isInfixOf` err)
        assertBool ("says the stack's region was used: " <> show err) ("; used the stack's region)" `T.isSuffixOf` err)
    Right r -> assertBool ("expected a failure, got " <> show r) False

-- | Run the request for the fixture.
runRequest :: MockAws -> IO (Either Text Int)
runRequest mock = do
    mcfn <- newMockCfnContext mock OpTemplateApprovalRequest "test"
    templateApprovalRequest (mcContext mcfn) (approvalArgs (Just simpleTemplate)) False Nothing

requestTests :: [TestTree]
requestTests =
    [ testCase "stack in eu-west-1, bucket in us-east-1 (empty location)" $
        requestCalls "eu-west-1" (Just "")
            >>= ( @?=
                    [ ("GetBucketLocation", "us-east-1")
                    , ("HeadObject", "us-east-1")
                    , ("PutObject", "us-east-1")
                    ]
                )
    , testCase "stack in eu-west-1, location answered as us-east-1" $
        requestCalls "eu-west-1" (Just "us-east-1")
            >>= ( @?=
                    [ ("GetBucketLocation", "us-east-1")
                    , ("HeadObject", "us-east-1")
                    , ("PutObject", "us-east-1")
                    ]
                )
    , testCase "stack in us-east-1, bucket in eu-west-1" $
        requestCalls "us-east-1" (Just "eu-west-1")
            >>= ( @?=
                    [ ("GetBucketLocation", "us-east-1")
                    , ("HeadObject", "eu-west-1")
                    , ("PutObject", "eu-west-1")
                    ]
                )
    , testCase "legacy EU location is eu-west-1" $
        requestCalls "us-east-1" (Just "EU")
            >>= ( @?=
                    [ ("GetBucketLocation", "us-east-1")
                    , ("HeadObject", "eu-west-1")
                    , ("PutObject", "eu-west-1")
                    ]
                )
    , testCase "GetBucketLocation denied: falls back to the stack's region" $
        requestCalls "eu-west-1" Nothing
            >>= ( @?=
                    [ ("GetBucketLocation", "us-east-1")
                    , ("HeadObject", "eu-west-1")
                    , ("PutObject", "eu-west-1")
                    ]
                )
    ]

reviewTests :: [TestTree]
reviewTests =
    [ testCase "stack in eu-west-1, bucket in us-east-1: no --region needed" $ do
        mock <- mockWithLocation "eu-west-1" (Just "")
        mcfn <- newMockCfnContext mock OpTemplateApprovalReview "test"
        result <- templateApprovalReview (mcContext mcfn) ("s3://approvals/" <> simplePendingKey) 3
        result @?= Left ("Pending template not found at s3://approvals/" <> simplePendingKey)
        callRegions mock
            >>= (@?= [("GetBucketLocation", "us-east-1"), ("HeadObject", "us-east-1")])
    ]

{- | Run the request for the fixture with the env in this region and the
bucket location answered as given ('Nothing': denied with 403); the
operations and the regions they were sent to.
-}
requestCalls :: Text -> Maybe ByteString -> IO [(Text, Text)]
requestCalls envRegion location = do
    mock <- mockWithLocation envRegion location
    mcfn <- newMockCfnContext mock OpTemplateApprovalRequest "test"
    result <- templateApprovalRequest (mcContext mcfn) (approvalArgs (Just simpleTemplate)) False Nothing
    result @?= Right 0
    callRegions mock

-- | A mock env in this region whose bucket location is answered as given.
mockWithLocation :: Text -> Maybe ByteString -> IO MockAws
mockWithLocation envRegion location = do
    mock <- newMockAwsIn (Amazonka.Region' envRegion)
    mockRespond
        mock
        (OnOperation "s3" "GetBucketLocation")
        (maybe (mockStatus 403) bucketLocationReply location)
    pure mock

-- | Each logged S3 operation and the region its host names.
callRegions :: MockAws -> IO [(Text, Text)]
callRegions mock = do
    logged <- mockRequestLog mock
    pure
        [ (callOperation call, region)
        | r <- logged
        , Just call <- [reqCall r]
        , Just region <- [s3HostRegion r]
        ]
