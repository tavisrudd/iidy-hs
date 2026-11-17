{- | The approval bucket's region: request and review send their S3 calls to
the bucket's own region (from @GetBucketLocation@, asked of us-east-1),
falling back to the stack's region when that call fails.
-}
module Test.ApprovalRegionTest (approvalRegionTests) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Amazonka qualified

import Iidy.Cfn.Operations.TemplateApproval (templateApprovalRequest, templateApprovalReview)
import Iidy.Cfn.Types (CfnOperation (..))
import Test.ApprovalFixtures (approvalArgs, simplePendingKey, simpleTemplate)
import Test.MockAws
import Test.MockCfnContext (MockCfn (..), newMockCfnContext)

approvalRegionTests :: [TestTree]
approvalRegionTests =
    [ testGroup "request" requestTests
    , testGroup "review" reviewTests
    ]

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
