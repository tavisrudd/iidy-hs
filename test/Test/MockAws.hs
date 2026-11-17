{- | In-process mock AWS for tests: an 'Amazonka.Env' whose HTTP connections
never open a socket.

The env carries static fake keys and an @http-client@ 'Client.Manager'
whose raw and TLS connection factories return a fake 'Connection'. The
fake collects the request bytes, works out the service and operation, and
replies:

* S3 REST requests (host @\<bucket\>.s3[.\<region\>].amazonaws.com@ or the
  path-style @s3[.\<region\>].amazonaws.com/\<bucket\>@): the method maps
  to @HeadObject@, @GetObject@, @PutObject@ or @DeleteObject@, and
  @GET /?location@ to @GetBucketLocation@. Without an override each
  operation has a built-in default (see 's3Default'): objects are absent,
  writes succeed, and the bucket is in us-east-1.
* JSON-protocol services (e.g. SSM): the @X-Amz-Target@ header
  @AmazonSSM.GetParameter@ maps to @ssm.GetParameter.json@.
* Query-protocol services (e.g. CloudFormation): the @Action=@ form field
  maps to @cloudformation.DescribeStacks.xml@.

For JSON and query requests the service name is the first label of the
@Host@ header and the canned body is read from 'mockAwsFixtureDir'. A
request with no override and no matching fixture gets an HTTP 400, so a
missing fixture fails loudly.

'mockRespond' overrides the reply for an operation ('OnOperation') or for
one S3 object ('OnObject'); an object override wins over an operation
override. Every request is recorded raw in 'mockLog'.
-}
module Test.MockAws (
    MockAws (..),
    MockCall (..),
    MockRequest (..),
    MockMatch (..),
    MockResponse (..),
    newMockAws,
    newMockAwsIn,
    mockRespond,
    mockRequestLog,
    mockStatus,
    mockAwsFixtureDir,
    parseRequest,
    recordingEnvFactory,
) where

import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (toLower)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types.URI (urlDecode)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Text.Read (readMaybe)

import Amazonka qualified
import Amazonka.Auth.Keys qualified as Keys
import Network.HTTP.Client qualified as Client
import Network.HTTP.Client.Internal (Connection, makeConnection)

import Iidy.Aws.CredentialSource (AwsSettings)

{- | A mock env, the log of fixture file names it looked up for JSON and
query requests (such as @ssm.GetParameter.json@), the raw log of every
request, and the reply overrides; logs are in request order.
-}
data MockAws = MockAws
    { mockEnv :: !Amazonka.Env
    , mockRequests :: !(IORef [FilePath])
    , mockLog :: !(IORef [MockRequest])
    , mockOverrides :: !(IORef (Map MockMatch MockResponse))
    }

-- | The operation a request was recognised as.
data MockCall = MockCall
    { callService :: !Text
    -- ^ for example @s3@ or @cloudformation@
    , callOperation :: !Text
    -- ^ for example @HeadObject@ or @DescribeStacks@
    , callBucket :: !(Maybe Text)
    -- ^ S3 only
    , callKey :: !(Maybe Text)
    -- ^ S3 object operations only (URL-decoded)
    }
    deriving (Show, Eq)

-- | One request as the mock received it.
data MockRequest = MockRequest
    { reqMethod :: !ByteString
    , reqHost :: !ByteString
    , reqPath :: !ByteString
    -- ^ path and query string, as sent
    , reqHeaders :: ![(ByteString, ByteString)]
    -- ^ lower-cased names, trimmed values
    , reqBody :: !ByteString
    , reqCall :: !(Maybe MockCall)
    }
    deriving (Show, Eq)

-- | What an override applies to.
data MockMatch
    = -- | every request for this service and operation
      OnOperation !Text !Text
    | -- | one S3 operation on one object: operation, bucket, key
      OnObject !Text !Text !Text
    deriving (Show, Eq, Ord)

-- | A canned reply: HTTP status and body.
data MockResponse = MockResponse
    { respStatus :: !Int
    , respBody :: !ByteString
    }
    deriving (Show, Eq)

-- | Directory holding the canned AWS responses.
mockAwsFixtureDir :: FilePath
mockAwsFixtureDir = "test-fixtures/mock-aws"

-- | Build a mock env in region us-east-1 with retries disabled.
newMockAws :: IO MockAws
newMockAws = newMockAwsIn (Amazonka.Region' "us-east-1")

-- | Build a mock env in the given region with retries disabled.
newMockAwsIn :: Amazonka.Region -> IO MockAws
newMockAwsIn region = do
    served <- newIORef []
    rawLog <- newIORef []
    overrides <- newIORef Map.empty
    let st = MockState served rawLog overrides
        factory = pure (\_ _ _ -> fakeConnection st)
        settings =
            Client.defaultManagerSettings
                { Client.managerRawConnection = factory
                , Client.managerTlsConnection = factory
                }
    manager <- Client.newManager settings
    noAuth <- Amazonka.newEnvNoAuthFromManager manager
    let env =
            Amazonka.once $
                Keys.fromKeys
                    (Amazonka.AccessKey "AKIAMOCKMOCKMOCKMOCK")
                    (Amazonka.SecretKey "mock-secret-key")
                    noAuth{Amazonka.region = region}
    pure
        MockAws
            { mockEnv = env
            , mockRequests = served
            , mockLog = rawLog
            , mockOverrides = overrides
            }

{- | An env factory that serves the mock env whatever it is asked for, and
an action reading the settings it was asked for, in call order.
-}
recordingEnvFactory :: MockAws -> IO (AwsSettings -> IO Amazonka.Env, IO [AwsSettings])
recordingEnvFactory mock = do
    asked <- newIORef []
    let factory settings = do
            atomicModifyIORef' asked (\xs -> (xs <> [settings], ()))
            pure (mockEnv mock)
    pure (factory, readIORef asked)

-- | Override the reply for every later request the match covers.
mockRespond :: MockAws -> MockMatch -> MockResponse -> IO ()
mockRespond mock match resp =
    atomicModifyIORef' (mockOverrides mock) (\m -> (Map.insert match resp m, ()))

-- | The raw requests received so far, in order.
mockRequestLog :: MockAws -> IO [MockRequest]
mockRequestLog = readIORef . mockLog

-- | A reply with this status and an empty body.
mockStatus :: Int -> MockResponse
mockStatus code = MockResponse code BS.empty

-- | The mutable parts of a mock shared by its connections.
data MockState = MockState
    { msServed :: !(IORef [FilePath])
    , msLog :: !(IORef [MockRequest])
    , msOverrides :: !(IORef (Map MockMatch MockResponse))
    }

{- | One fake connection serves one request: it buffers writes, and on a
read builds the full response from the buffered request. A request sent
with @Expect: 100-continue@ whose body has not arrived yet gets an interim
@100 Continue@ first, so the client sends the body.
-}
fakeConnection :: MockState -> IO Connection
fakeConnection st = do
    written <- newIORef BS.empty
    finished <- newIORef False
    continued <- newIORef False
    let write bs = atomicModifyIORef' written (\acc -> (acc <> bs, ()))
        readChunk = do
            done <- readIORef finished
            if done
                then pure BS.empty
                else do
                    raw <- readIORef written
                    sentContinue <- readIORef continued
                    case parseRequest raw of
                        Just req
                            | awaitsBody req && not sentContinue -> do
                                writeIORef continued True
                                pure "HTTP/1.1 100 Continue\r\n\r\n"
                        mReq -> do
                            writeIORef finished True
                            respond st mReq
    makeConnection readChunk write (pure ())

-- | True when the request asked for @100-continue@ and its body is short.
awaitsBody :: MockRequest -> Bool
awaitsBody req =
    let expects = fmap (BC.map toLower) (lookup "expect" (reqHeaders req)) == Just "100-continue"
        declared = lookup "content-length" (reqHeaders req) >>= readMaybe . BC.unpack
     in expects && maybe False (> BS.length (reqBody req)) declared

-- | Log the request and build the raw HTTP response for it.
respond :: MockState -> Maybe MockRequest -> IO ByteString
respond _ Nothing = pure (httpResponse "GET" (MockResponse 400 "unparseable request"))
respond st (Just req) = do
    atomicModifyIORef' (msLog st) (\rs -> (rs <> [req], ()))
    overrides <- readIORef (msOverrides st)
    let override = reqCall req >>= lookupOverride overrides
    resp <- case (override, reqCall req) of
        (Just r, _) -> pure r
        (Nothing, Just call)
            | callService call == "s3" -> pure (s3Default (callOperation call))
        (Nothing, _) -> fromFixture st req
    pure (httpResponse (reqMethod req) resp)

-- | The override for a call: one for its object first, then its operation.
lookupOverride :: Map MockMatch MockResponse -> MockCall -> Maybe MockResponse
lookupOverride overrides call =
    objectMatch <|> Map.lookup (OnOperation (callService call) (callOperation call)) overrides
  where
    objectMatch = do
        bucket <- callBucket call
        key <- callKey call
        Map.lookup (OnObject (callOperation call) bucket key) overrides

-- | Serve a JSON or query request from its fixture file.
fromFixture :: MockState -> MockRequest -> IO MockResponse
fromFixture st req = case fixtureKey req of
    Nothing -> pure (MockResponse 400 "no fixture key in request")
    Just key -> do
        atomicModifyIORef' (msServed st) (\ks -> (ks <> [key], ()))
        let path = mockAwsFixtureDir </> key
        exists <- doesFileExist path
        if exists
            then MockResponse 200 <$> BS.readFile path
            else pure (MockResponse 400 (BC.pack ("missing mock fixture " <> path)))

-- | The reply to an S3 operation with no override.
s3Default :: Text -> MockResponse
s3Default = \case
    "HeadObject" -> mockStatus 404
    "GetObject" -> MockResponse 404 (s3Error "NoSuchKey" "The specified key does not exist.")
    "PutObject" -> mockStatus 200
    "DeleteObject" -> mockStatus 204
    "GetBucketLocation" ->
        MockResponse 200 "<LocationConstraint xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"/>"
    other -> MockResponse 400 ("unsupported mock S3 operation " <> TE.encodeUtf8 other)

-- | An S3 REST error body.
s3Error :: ByteString -> ByteString -> ByteString
s3Error code message =
    "<Error><Code>" <> code <> "</Code><Message>" <> message <> "</Message></Error>"

------------------------------------------------------------------------
-- Request parsing
------------------------------------------------------------------------

-- | Split a raw HTTP request into its parts and recognise the operation.
parseRequest :: ByteString -> Maybe MockRequest
parseRequest raw = do
    let (headBytes, rest) = BS.breakSubstring "\r\n\r\n" raw
        body = BS.drop 4 rest
        headLines = BC.lines (BC.filter (/= '\r') headBytes)
        headers = mapMaybe splitHeader (drop 1 headLines)
    (method, path) <- case BC.words =<< take 1 headLines of
        m : p : _ -> Just (m, p)
        _ -> Nothing
    host <- lookup "host" headers
    let req =
            MockRequest
                { reqMethod = method
                , reqHost = host
                , reqPath = path
                , reqHeaders = headers
                , reqBody = body
                , reqCall = Nothing
                }
    pure req{reqCall = s3Call req <|> protocolCall req}

-- | Recognise an S3 REST request from its host, method and path.
s3Call :: MockRequest -> Maybe MockCall
s3Call req = do
    let labels = BC.split '.' (BC.takeWhile (/= ':') (reqHost req))
        (pathPart, query) = BC.break (== '?') (reqPath req)
        segments = BC.split '/' (BS.drop 1 pathPart)
    -- The endpoint starts at the last S3 label, so a bucket name may
    -- itself contain or start with one (s3-approvals.s3.amazonaws.com).
    before <- case break isS3Label (reverse labels) of
        (_, _endpoint : bucketLabels) -> Just (reverse bucketLabels)
        (_, []) -> Nothing
    (bucket, keySegs) <-
        if null before
            then case segments of
                b : ks | not (BS.null b) -> Just (b, ks)
                _ -> Nothing
            else Just (BS.intercalate "." before, segments)
    let key = TE.decodeUtf8Lenient (urlDecode False (BS.intercalate "/" keySegs))
        isLocation = "location" `elem` map (BC.takeWhile (/= '=')) (BC.split '&' (BS.drop 1 query))
    op <- case reqMethod req of
        "GET" | isLocation && T.null key -> Just "GetBucketLocation"
        "HEAD" -> Just "HeadObject"
        "GET" -> Just "GetObject"
        "PUT" -> Just "PutObject"
        "DELETE" -> Just "DeleteObject"
        _ -> Nothing
    pure
        MockCall
            { callService = "s3"
            , callOperation = op
            , callBucket = Just (TE.decodeUtf8Lenient bucket)
            , callKey = if T.null key then Nothing else Just key
            }
  where
    isS3Label l = l == "s3" || "s3-" `BS.isPrefixOf` l

-- | Recognise a JSON-protocol or query-protocol request.
protocolCall :: MockRequest -> Maybe MockCall
protocolCall req = do
    (service, op, _ext) <- protocolParts req
    pure (MockCall (T.pack service) (T.pack op) Nothing Nothing)

-- | Service, operation and fixture extension of a JSON or query request.
protocolParts :: MockRequest -> Maybe (String, String, String)
protocolParts req = do
    let service = BC.unpack (BC.takeWhile (/= '.') (reqHost req))
    case lookup "x-amz-target" (reqHeaders req) of
        Just target -> Just (service, BC.unpack (BC.drop 1 (BC.dropWhile (/= '.') target)), "json")
        Nothing -> do
            action <- listToMaybe (mapMaybe (BS.stripPrefix "Action=") (BC.split '&' (reqBody req)))
            Just (service, BC.unpack action, "xml")

-- | Derive the fixture file name from the request's Host, target and body.
fixtureKey :: MockRequest -> Maybe FilePath
fixtureKey req = do
    (service, op, ext) <- protocolParts req
    Just (service <> "." <> op <> "." <> ext)

-- | Split @Name: value@ into a lower-cased name and a trimmed value.
splitHeader :: ByteString -> Maybe (ByteString, ByteString)
splitHeader line = case BC.break (== ':') line of
    (name, rest)
        | BS.null rest -> Nothing
        | otherwise -> Just (BC.map toLower name, BC.dropWhile (== ' ') (BS.drop 1 rest))

------------------------------------------------------------------------
-- Responses
------------------------------------------------------------------------

{- | Serialise a minimal HTTP/1.1 response that closes the connection. A
reply to @HEAD@ carries no body.
-}
httpResponse :: ByteString -> MockResponse -> ByteString
httpResponse method resp =
    BS.concat
        [ "HTTP/1.1 "
        , BC.pack (show status)
        , " "
        , reasonPhrase status
        , "\r\nContent-Length: "
        , BC.pack (show (BS.length body))
        , "\r\nConnection: close\r\n\r\n"
        , if method == "HEAD" then BS.empty else body
        ]
  where
    status = respStatus resp
    body = respBody resp

-- | The reason phrase for the statuses the mock serves.
reasonPhrase :: Int -> ByteString
reasonPhrase = \case
    200 -> "OK"
    204 -> "No Content"
    301 -> "Moved Permanently"
    400 -> "Bad Request"
    403 -> "Forbidden"
    404 -> "Not Found"
    500 -> "Internal Server Error"
    _ -> "Unknown"
