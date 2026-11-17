{- | Card C19: AWS and HTTP error messages must not carry the signed
request. A real 'Amazonka.TransportError' is produced by an env whose
connections are refused ('newRefusingMockAws'); the messages formatted
from it, and the @Left@ of an SSM and an S3 import run against it, must
hold the host but none of the fake credentials or the signature.
-}
module Test.AwsErrorTest (awsErrorTests) where

import Control.Exception (throwIO, toException)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Amazonka qualified
import Amazonka.Auth.Exception (AuthError (..))
import Amazonka.SSM.GetParameter qualified as GP
import Amazonka.Types qualified as AT
import Data.Text.Encoding qualified as TE
import Iidy.Aws.Errors (formatAwsError, formatHttpException)
import Iidy.Cfn.S3Objects (HeadResult (..), headObject, s3ObjectExists)
import Iidy.Yaml.Imports.Loaders.LazyEnv (tryBuildEnv)
import Iidy.Yaml.Imports.Loaders.S3 (loadS3Import)
import Iidy.Yaml.Imports.Loaders.Ssm (loadSsmImport)
import Iidy.Yaml.Imports.Types (ImportError (..))
import Network.HTTP.Client (HttpException (..), HttpExceptionContent (..), parseRequest_, requestHeaders)
import Network.HTTP.Client qualified as Client
import Network.HTTP.Client.Internal qualified as Client (Response (..), ResponseClose (..))
import Network.HTTP.Types (Status (..), http11, status400)
import Test.MockAws (mockAccessKey, mockSecretKey, mockSessionToken, newRefusingMockAws)

awsErrorTests :: [TestTree]
awsErrorTests =
    [ testGroup "formatAwsError" formatAwsErrorTests
    , testGroup "formatHttpException" formatHttpExceptionTests
    , testGroup
        "transport failure through the mock env"
        [ testCase "SSM import error names the host and holds no credential" $ do
            env <- newRefusingMockAws
            loadSsmImport env "ssm:/app/config" >>= assertImportLeak "ssm.us-east-1.amazonaws.com"
        , testCase "S3 import error names the host and holds no credential" $ do
            env <- newRefusingMockAws
            loadS3Import env "s3://some-bucket/config.yaml" >>= assertImportLeak "s3.us-east-1.amazonaws.com"
        , testCase "S3 head-object failure names no credential" $ do
            env <- newRefusingMockAws
            headObject env "approvals" "t.yaml" >>= \case
                ObjectHeadFailed msg -> assertClean "approvals.s3.us-east-1.amazonaws.com" msg
                other -> assertFailure ("expected ObjectHeadFailed, got " <> show other)
        , testCase "S3 existence check failure names no credential" $ do
            env <- newRefusingMockAws
            s3ObjectExists env "approvals" "t.yaml" >>= \case
                Left msg -> assertClean "approvals.s3.us-east-1.amazonaws.com" msg
                Right _ -> assertFailure "expected a failure"
        , testCase "a credential-retrieval failure names the host, not the request headers" $ do
            let he = HttpExceptionRequest (signedRequestOf "http://169.254.169.254/latest/api/token") ResponseTimeout
            tryBuildEnv (throwIO (RetrievalError he)) >>= \case
                Left msg -> assertClean "169.254.169.254" msg
                Right _ -> assertFailure "expected a failure"
        , testCase "an env provider that fails with a transport error names no credential" $ do
            env <- newRefusingMockAws
            let failing = Amazonka.runResourceT (Amazonka.send env (GP.newGetParameter "/x")) >> pure env
            tryBuildEnv failing >>= \case
                Left msg -> assertClean "ssm.us-east-1.amazonaws.com" msg
                Right _ -> assertFailure "expected a failure"
        ]
    ]

-- | The sensitive strings a message must never hold.
secrets :: [(String, Text)]
secrets =
    [ ("session token", mockSessionToken)
    , ("access key", mockAccessKey)
    , ("secret key", mockSecretKey)
    , ("signature", "Signature=")
    , ("credential scope", "Credential=")
    , ("authorization header", "Authorization")
    , ("security-token header", "X-Amz-Security-Token")
    ]

assertClean :: Text -> Text -> IO ()
assertClean host msg = do
    mapM_ (\(what, s) -> assertBool (what <> " leaked in: " <> T.unpack msg) (not (s `T.isInfixOf` msg))) secrets
    assertBool ("host missing in: " <> T.unpack msg) (host `T.isInfixOf` msg)

assertImportLeak :: Text -> Either ImportError a -> IO ()
assertImportLeak host = \case
    Left (ImportError msg) -> assertClean host msg
    Right _ -> assertFailure "expected the import to fail"

------------------------------------------------------------------------
-- Pure formatting
------------------------------------------------------------------------

formatAwsErrorTests :: [TestTree]
formatAwsErrorTests =
    [ testCase "ServiceError leaves out its response headers" $ do
        let err = Amazonka.ServiceError (AT.ServiceError' "SSM" status400 [("X-Secret", "hdr-secret")] (Amazonka.ErrorCode "Oops") Nothing Nothing)
        assertBool "no header value" (not ("hdr-secret" `T.isInfixOf` formatAwsError err))
    , testCase "TransportError carries the host, not the request" $ do
        let msg = formatAwsError (Amazonka.TransportError (signedRequest ConnectionTimeout))
        assertClean "ssm.us-east-1.amazonaws.com" msg
    , testCase "SerializeError names the service and not the body" $ do
        let err = Amazonka.SerializeError (AT.SerializeError' "CloudFormation" status400 (Just "body-secret") "bad xml")
            msg = formatAwsError err
        T.isInfixOf "CloudFormation" msg @?= True
        T.isInfixOf "bad xml" msg @?= True
        T.isInfixOf "body-secret" msg @?= False
    ]

formatHttpExceptionTests :: [TestTree]
formatHttpExceptionTests =
    [ testCase "connection failure shows the inner exception and the host" $ do
        let msg = formatHttpException (signedRequest (ConnectionFailure (toException (userError "connection refused"))))
        assertClean "ssm.us-east-1.amazonaws.com" msg
        assertBool "inner exception" ("connection refused" `T.isInfixOf` msg)
    , testCase "response timeout is named, with the host" $ do
        let msg = formatHttpException (signedRequest ResponseTimeout)
        assertClean "ssm.us-east-1.amazonaws.com" msg
        assertBool "timeout" ("timeout" `T.isInfixOf` msg)
    , testCase "a status-code exception has the status, not the headers" $ do
        let msg = formatHttpException (signedRequest (StatusCodeException (statusResponse 503) "body-secret"))
        assertClean "ssm.us-east-1.amazonaws.com" msg
        assertBool "status" ("503" `T.isInfixOf` msg)
        assertBool "no response header" (not ("cookie-secret" `T.isInfixOf` msg))
        assertBool "no body" (not ("body-secret" `T.isInfixOf` msg))
    , testCase "a presigned URL query is not in the message" $ do
        let req = parseRequest_ "https://bucket.s3.amazonaws.com/doc.yaml?X-Amz-Signature=sig-secret-123&X-Amz-Credential=cred-secret"
            msg = formatHttpException (HttpExceptionRequest req ResponseTimeout)
        assertBool "host" ("bucket.s3.amazonaws.com" `T.isInfixOf` msg)
        mapM_ (\bad -> assertBool bad (not (T.pack bad `T.isInfixOf` msg))) ["sig-secret-123", "cred-secret", "X-Amz"]
    , testCase "an invalid URL keeps the reason only" $
        formatHttpException (InvalidUrlException "https://h/?X-Amz-Signature=sig-secret" "no host")
            @?= "invalid URL: no host"
    ]

-- | A request as Amazonka signs it: session token and credentials in the headers.
signedRequest :: HttpExceptionContent -> HttpException
signedRequest = HttpExceptionRequest (signedRequestOf "https://ssm.us-east-1.amazonaws.com/?X-Amz-Signature=sig-secret")

-- | A request to this URL carrying the session token and credentials in its headers.
signedRequestOf :: String -> Client.Request
signedRequestOf url =
    (parseRequest_ url)
        { requestHeaders =
            [ ("X-Amz-Security-Token", TE.encodeUtf8 mockSessionToken)
            , ("Authorization", "AWS4-HMAC-SHA256 Credential=" <> TE.encodeUtf8 mockAccessKey <> "/x, Signature=sig")
            ]
        }

statusResponse :: Int -> Client.Response ()
statusResponse code =
    Client.Response
        { Client.responseStatus = Status code "Service Unavailable"
        , Client.responseVersion = http11
        , Client.responseHeaders = [("Set-Cookie", "cookie-secret")]
        , Client.responseBody = ()
        , Client.responseEarlyHints = []
        , Client.responseCookieJar = Client.createCookieJar []
        , Client.responseClose' = Client.ResponseClose (pure ())
        , Client.responseOriginalRequest = parseRequest_ "https://ssm.us-east-1.amazonaws.com/"
        }
