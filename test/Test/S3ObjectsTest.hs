{- | Tests for the S3 object helpers ('Iidy.Cfn.S3Objects') through the mock
AWS env.
-}
module Test.S3ObjectsTest (s3ObjectsTests) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Amazonka qualified
import Amazonka.Auth.Keys qualified as Keys

import Iidy.Cfn.S3Objects (HeadResult (..), headObject, presignGetObject, s3ObjectExists)
import Test.MockAws
import Test.MockCfnContext (mockCfnTime)

s3ObjectsTests :: [TestTree]
s3ObjectsTests =
    [ testGroup "headObject outcomes" headTests
    , testGroup "presignGetObject" presignTests
    ]

presignTests :: [TestTree]
presignTests =
    [ testCase "static keys, us-east-1: host, path, date, expiry, scope, signature" $ do
        mock <- newMockAws
        url <- presignGetObject (mockEnv mock) mockCfnTime "approvals" "app/t.yaml"
        assertPrefix "https://approvals.s3.us-east-1.amazonaws.com/app/t.yaml?" url
        mapM_
            (`assertParam` url)
            [ "X-Amz-Algorithm=AWS4-HMAC-SHA256"
            , "X-Amz-Date=20260101T000000Z"
            , "X-Amz-Expires=900"
            , "X-Amz-Credential=AKIAMOCKMOCKMOCKMOCK%2F20260101%2Fus-east-1%2Fs3%2Faws4_request"
            ]
        assertBool ("signed: " <> show url) ("X-Amz-Signature=" `T.isInfixOf` url)
        assertBool ("no session token: " <> show url) (not ("X-Amz-Security-Token" `T.isInfixOf` url))
        logged <- mockRequestLog mock
        length logged @?= 0
    , testCase "eu-west-1 env: host and credential scope name eu-west-1" $ do
        mock <- newMockAwsIn (Amazonka.Region' "eu-west-1")
        url <- presignGetObject (mockEnv mock) mockCfnTime "approvals" "app/t.yaml"
        assertPrefix "https://approvals.s3.eu-west-1.amazonaws.com/app/t.yaml?" url
        assertParam "X-Amz-Credential=AKIAMOCKMOCKMOCKMOCK%2F20260101%2Feu-west-1%2Fs3%2Faws4_request" url
    , testCase "dotted bucket name: path style (iidy-js sends path style for every bucket)" $ do
        mock <- newMockAws
        url <- presignGetObject (mockEnv mock) mockCfnTime "my.approvals" "t.yaml"
        assertPrefix "https://s3.us-east-1.amazonaws.com/my.approvals/t.yaml?" url
    , testCase "session keys: the URL carries X-Amz-Security-Token" $ do
        mock <- newMockAws
        let env =
                Keys.fromSession
                    (Amazonka.AccessKey "ASIAMOCKMOCKMOCKMOCK")
                    (Amazonka.SecretKey "mock-secret-key")
                    (Amazonka.SessionToken "mock-session-token")
                    (mockEnv mock)
        url <- presignGetObject env mockCfnTime "approvals" "app/t.yaml"
        assertParam "X-Amz-Security-Token=mock-session-token" url
        assertParam "X-Amz-Credential=ASIAMOCKMOCKMOCKMOCK%2F20260101%2Fus-east-1%2Fs3%2Faws4_request" url
    ]

-- | The URL starts with this text.
assertPrefix :: Text -> Text -> IO ()
assertPrefix prefix url = assertBool ("expected prefix " <> show prefix <> " in " <> show url) (prefix `T.isPrefixOf` url)

-- | The URL's query string has this exact parameter.
assertParam :: Text -> Text -> IO ()
assertParam param url =
    assertBool
        ("expected " <> show param <> " in " <> show url)
        (param `elem` T.splitOn "&" (T.drop 1 (T.dropWhile (/= '?') url)))

headTests :: [TestTree]
headTests =
    [ testCase "200 is present" $ headWith 200 >>= (@?= ObjectPresent)
    , testCase "404 is missing" $ headWith 404 >>= (@?= ObjectMissing)
    , testCase "403 is access denied" $ headWith 403 >>= (@?= ObjectAccessDenied)
    , testCase "500 is a failure with the error text" $ do
        result <- headWith 500
        case result of
            ObjectHeadFailed err -> assertBool ("names the status text: " <> show err) ("Internal Server Error" `T.isInfixOf` err)
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
