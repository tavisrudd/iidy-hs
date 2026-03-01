module Test.ChangesetHelpersTest (changesetHelpersTests) where

import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

import Iidy.Cfn.Operations.Changeset
  ( percentEncode
  , extractRegionFromArn
  , buildChangesetConsoleUrl
  , buildChangeSetCreationResult
  )
import Iidy.Output.Types (ChangeSetInfo(..), ChangeSetCreationResult(..), ChangeInfo(..))

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | A minimal ChangeSetInfo for testing buildChangeSetCreationResult.
minimalCsInfo :: ChangeSetInfo
minimalCsInfo = ChangeSetInfo
  { csiChangeSetName   = "my-changeset"
  , csiChangeSetId     = "arn:aws:cloudformation:us-east-1:123456789012:changeSet/my-changeset/abc-123"
  , csiStackId         = "arn:aws:cloudformation:us-east-1:123456789012:stack/my-stack/def-456"
  , csiStackName       = "my-stack"
  , csiDescription     = Nothing
  , csiStatus          = "CREATE_COMPLETE"
  , csiStatusReason    = Nothing
  , csiCreationTime    = Nothing
  , csiExecutionStatus = Just "AVAILABLE"
  , csiChanges         = []
  }

------------------------------------------------------------------------
-- percentEncode tests
------------------------------------------------------------------------

percentEncodeTests :: [TestTree]
percentEncodeTests =
  [ testCase "empty string encodes to empty string" $
      percentEncode "" @?= ""

  , testCase "ASCII letters pass through unchanged" $
      percentEncode "abcXYZ" @?= "abcXYZ"

  , testCase "digits pass through unchanged" $
      percentEncode "0123456789" @?= "0123456789"

  , testCase "unreserved special chars pass through" $
      -- RFC 3986 unreserved: ALPHA / DIGIT / '-' / '.' / '_' / '~'
      percentEncode "-._~" @?= "-._~"

  , testCase "colon is percent-encoded" $
      percentEncode ":" @?= "%3A"

  , testCase "slash is percent-encoded" $
      percentEncode "/" @?= "%2F"

  , testCase "ARN colons and slashes are encoded" $ do
      let arn = "arn:aws:cloudformation:us-east-1:123456789012:stack/my-stack/abc"
          encoded = percentEncode arn
      assertBool "encoded should not contain :" (not (T.isInfixOf ":" encoded))
      assertBool "encoded should not contain /" (not (T.isInfixOf "/" encoded))
      assertBool "encoded should contain %3A" (T.isInfixOf "%3A" encoded)
      assertBool "encoded should contain %2F" (T.isInfixOf "%2F" encoded)

  , testCase "space is percent-encoded as %20" $
      percentEncode " " @?= "%20"

  , testCase "hash is percent-encoded" $
      percentEncode "#" @?= "%23"

  , testCase "simple alphanumeric string is identity" $
      percentEncode "hello123" @?= "hello123"

  , testCase "Unicode is percent-encoded as UTF-8 bytes" $ do
      let encoded = percentEncode "\x00e9"  -- é = U+00E9, UTF-8: 0xC3 0xA9
      -- UTF-8 encoding of é is 0xC3 0xA9 → %C3%A9
      encoded @?= "%C3%A9"
  ]

------------------------------------------------------------------------
-- extractRegionFromArn tests
------------------------------------------------------------------------

extractRegionTests :: [TestTree]
extractRegionTests =
  [ testCase "extracts region from standard CloudFormation ARN" $
      extractRegionFromArn
        "arn:aws:cloudformation:us-east-1:123456789012:stack/my-stack/abc"
        @?= "us-east-1"

  , testCase "extracts region from us-west-2 ARN" $
      extractRegionFromArn
        "arn:aws:cloudformation:us-west-2:123456789012:stack/my-stack/abc"
        @?= "us-west-2"

  , testCase "extracts region from eu-central-1 ARN" $
      extractRegionFromArn
        "arn:aws:cloudformation:eu-central-1:123456789012:stack/my-stack/abc"
        @?= "eu-central-1"

  , testCase "extracts region from changeset ARN" $
      extractRegionFromArn
        "arn:aws:cloudformation:ap-southeast-1:123456789012:changeSet/my-cs/xyz"
        @?= "ap-southeast-1"

  , testCase "falls back to us-east-1 for malformed ARN (too few colons)" $
      extractRegionFromArn "not-an-arn" @?= "us-east-1"

  , testCase "falls back to us-east-1 for empty string" $
      extractRegionFromArn "" @?= "us-east-1"
  ]

------------------------------------------------------------------------
-- buildChangesetConsoleUrl tests
------------------------------------------------------------------------

buildChangesetConsoleUrlTests :: [TestTree]
buildChangesetConsoleUrlTests =
  [ testCase "produces valid HTTPS URL" $ do
      let url = buildChangesetConsoleUrl "us-east-1"
                  "arn:aws:cloudformation:us-east-1:123:stack/my-stack/id"
                  "arn:aws:cloudformation:us-east-1:123:changeSet/my-cs/id"
      assertBool "starts with https://" (T.isPrefixOf "https://" url)

  , testCase "URL contains region in host and query" $ do
      let url = buildChangesetConsoleUrl "us-east-1"
                  "arn:aws:cloudformation:us-east-1:123:stack/my-stack/id"
                  "arn:aws:cloudformation:us-east-1:123:changeSet/my-cs/id"
      assertBool "contains us-east-1.console.aws.amazon.com"
        (T.isInfixOf "us-east-1.console.aws.amazon.com" url)
      assertBool "contains region= query"
        (T.isInfixOf "region=us-east-1" url)

  , testCase "URL contains percent-encoded stackId" $ do
      let url = buildChangesetConsoleUrl "us-east-1"
                  "arn:aws:cloudformation:us-east-1:123:stack/my-stack/id"
                  "arn:aws:cloudformation:us-east-1:123:changeSet/my-cs/id"
      assertBool "contains stackId parameter"
        (T.isInfixOf "stackId=" url)
      -- ARN colons should be encoded
      assertBool "stackId value contains %3A"
        (T.isInfixOf "%3A" url)

  , testCase "URL contains percent-encoded changeSetId" $ do
      let url = buildChangesetConsoleUrl "us-west-2"
                  "arn:aws:cloudformation:us-west-2:456:stack/s/id"
                  "arn:aws:cloudformation:us-west-2:456:changeSet/cs/id"
      assertBool "contains changeSetId parameter"
        (T.isInfixOf "changeSetId=" url)

  , testCase "different regions produce different URLs" $ do
      let url1 = buildChangesetConsoleUrl "us-east-1" "arn1" "cs1"
          url2 = buildChangesetConsoleUrl "eu-west-1" "arn1" "cs1"
      assertBool "URLs should differ" (url1 /= url2)
  ]

------------------------------------------------------------------------
-- buildChangeSetCreationResult tests
------------------------------------------------------------------------

buildChangeSetCreationResultTests :: [TestTree]
buildChangeSetCreationResultTests =
  [ testCase "UPDATE type when stackExists = True" $ do
      let result = buildChangeSetCreationResult minimalCsInfo True "stack-args.yaml"
      csrChangesetType result @?= "UPDATE"

  , testCase "CREATE type when stackExists = False" $ do
      let result = buildChangeSetCreationResult minimalCsInfo False "stack-args.yaml"
      csrChangesetType result @?= "CREATE"

  , testCase "changeset name from ChangeSetInfo" $ do
      let result = buildChangeSetCreationResult minimalCsInfo True "stack-args.yaml"
      csrChangesetName result @?= "my-changeset"

  , testCase "stack name from ChangeSetInfo" $ do
      let result = buildChangeSetCreationResult minimalCsInfo True "stack-args.yaml"
      csrStackName result @?= "my-stack"

  , testCase "status from ChangeSetInfo" $ do
      let result = buildChangeSetCreationResult minimalCsInfo True "stack-args.yaml"
      csrStatus result @?= "CREATE_COMPLETE"

  , testCase "pending changesets contains the input info" $ do
      let result = buildChangeSetCreationResult minimalCsInfo True "stack-args.yaml"
      csrPendingChangesets result @?= [minimalCsInfo]

  , testCase "hasChanges False when changes list is empty" $ do
      let result = buildChangeSetCreationResult minimalCsInfo True "stack-args.yaml"
      csrHasChanges result @?= False

  , testCase "hasChanges True when changes list is non-empty" $ do
      let dummyChange = ChangeInfo
            { ciAction            = "Add"
            , ciLogicalResourceId = "MyBucket"
            , ciPhysicalResourceId = Nothing
            , ciResourceType      = "AWS::S3::Bucket"
            , ciReplacement       = Nothing
            , ciScope             = Nothing
            , ciDetails           = []
            }
          infoWithChanges = minimalCsInfo { csiChanges = [dummyChange] }
          result = buildChangeSetCreationResult infoWithChanges True "stack-args.yaml"
      csrHasChanges result @?= True

  , testCase "console URL is HTTPS" $ do
      let result = buildChangeSetCreationResult minimalCsInfo True "stack-args.yaml"
      assertBool "console URL starts with https://"
        (T.isPrefixOf "https://" (csrConsoleUrl result))

  , testCase "next steps contain exec-changeset command" $ do
      let result = buildChangeSetCreationResult minimalCsInfo True "stack-args.yaml"
      let steps = T.unwords (csrNextSteps result)
      assertBool "next steps mention exec-changeset"
        (T.isInfixOf "exec-changeset" steps)
  ]

------------------------------------------------------------------------
-- Top-level export
------------------------------------------------------------------------

changesetHelpersTests :: [TestTree]
changesetHelpersTests =
  [ testGroup "percentEncode"             percentEncodeTests
  , testGroup "extractRegionFromArn"      extractRegionTests
  , testGroup "buildChangesetConsoleUrl"  buildChangesetConsoleUrlTests
  , testGroup "buildChangeSetCreationResult" buildChangeSetCreationResultTests
  ]
