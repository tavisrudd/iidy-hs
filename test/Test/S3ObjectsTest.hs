{- | Tests for the S3 object helpers ('Iidy.Cfn.S3Objects') through the mock
AWS env.
-}
module Test.S3ObjectsTest (s3ObjectsTests) where

import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Amazonka qualified

import Iidy.Cfn.S3Objects (HeadResult (..), headObject, s3ObjectExists)
import Test.MockAws

s3ObjectsTests :: [TestTree]
s3ObjectsTests =
    [ testGroup "headObject outcomes" headTests
    ]

headTests :: [TestTree]
headTests =
    [ testCase "200 is present" $ headWith 200 >>= (@?= ObjectPresent)
    , testCase "404 is missing" $ headWith 404 >>= (@?= ObjectMissing)
    , testCase "403 is access denied" $ headWith 403 >>= (@?= ObjectAccessDenied)
    , testCase "500 is a failure with the error text" $ do
        result <- headWith 500
        case result of
            ObjectHeadFailed err -> assertBool ("names the status: " <> show err) ("500" `T.isInfixOf` err)
            other -> assertBool ("expected a failure, got " <> show other) False
    , testCase "s3ObjectExists: a failure names the env's region" $ do
        mock <- newMockAwsIn (Amazonka.Region' "eu-west-1")
        mockRespond mock (OnOperation "s3" "HeadObject") (mockStatus 500)
        result <- s3ObjectExists (mockEnv mock) "approvals" "t.yaml"
        assertBool
            ("names eu-west-1: " <> show result)
            (either ("Failed to check s3://approvals/t.yaml in region eu-west-1: " `T.isPrefixOf`) (const False) result)
    , testCase "s3ObjectExists: present and missing" $ do
        mock <- newMockAws
        mockRespond mock (OnObject "HeadObject" "approvals" "here.yaml") (mockStatus 200)
        present <- s3ObjectExists (mockEnv mock) "approvals" "here.yaml"
        missing <- s3ObjectExists (mockEnv mock) "approvals" "gone.yaml"
        (present, missing) @?= (Right True, Right False)
    ]

-- | HEAD one object whose reply has this status.
headWith :: Int -> IO HeadResult
headWith status = do
    mock <- newMockAws
    mockRespond mock (OnObject "HeadObject" "approvals" "t.yaml") (mockStatus status)
    headObject (mockEnv mock) "approvals" "t.yaml"
