{- | In-process mock AWS for tests: an 'Amazonka.Env' whose HTTP connections
never open a socket.

The env carries static fake keys and an @http-client@ 'Client.Manager'
whose raw and TLS connection factories return a fake 'Connection'. The
fake collects the request bytes, works out the service and operation, and
replies with a canned body read from 'mockAwsFixtureDir':

* JSON-protocol services (e.g. SSM): the @X-Amz-Target@ header
  @AmazonSSM.GetParameter@ maps to @ssm.GetParameter.json@.
* Query-protocol services (e.g. CloudFormation): the @Action=@ form field
  maps to @cloudformation.DescribeStacks.xml@.

The service name is the first label of the @Host@ header. A request with
no matching fixture gets an HTTP 400, so a missing fixture fails loudly.
-}
module Test.MockAws (
    MockAws (..),
    newMockAws,
    mockAwsFixtureDir,
    recordingEnvFactory,
) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (toLower)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (listToMaybe, mapMaybe)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Amazonka qualified
import Amazonka.Auth.Keys qualified as Keys
import Network.HTTP.Client qualified as Client
import Network.HTTP.Client.Internal (Connection, makeConnection)

import Iidy.Aws.CredentialSource (AwsSettings)

{- | A mock env plus the log of fixture file names it served (such as
@ssm.GetParameter.json@), in request order.
-}
data MockAws = MockAws
    { mockEnv :: !Amazonka.Env
    , mockRequests :: !(IORef [FilePath])
    }

-- | Directory holding the canned AWS responses.
mockAwsFixtureDir :: FilePath
mockAwsFixtureDir = "test-fixtures/mock-aws"

-- | Build a mock env in region us-east-1 with retries disabled.
newMockAws :: IO MockAws
newMockAws = do
    reqLog <- newIORef []
    let factory = pure (\_ _ _ -> fakeConnection reqLog)
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
                    noAuth{Amazonka.region = Amazonka.Region' "us-east-1"}
    pure MockAws{mockEnv = env, mockRequests = reqLog}

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

{- | One fake connection serves one request: it buffers writes, and on the
first read builds the full response from the buffered request.
-}
fakeConnection :: IORef [FilePath] -> IO Connection
fakeConnection reqLog = do
    written <- newIORef BS.empty
    pending <- newIORef Nothing
    let write bs = atomicModifyIORef' written (\acc -> (acc <> bs, ()))
        readChunk = do
            mResp <- readIORef pending
            remaining <- case mResp of
                Just r -> pure r
                Nothing -> do
                    req <- readIORef written
                    respond reqLog req
            writeIORef pending (Just BS.empty)
            pure remaining
    makeConnection readChunk write (pure ())

-- | Build the raw HTTP response for a raw HTTP request.
respond :: IORef [FilePath] -> ByteString -> IO ByteString
respond reqLog req = case fixtureKey req of
    Nothing -> pure (httpResponse 400 "no fixture key in request")
    Just key -> do
        atomicModifyIORef' reqLog (\ks -> (ks <> [key], ()))
        let path = mockAwsFixtureDir </> key
        exists <- doesFileExist path
        if exists
            then httpResponse 200 <$> BS.readFile path
            else pure (httpResponse 400 (BC.pack ("missing mock fixture " <> path)))

-- | Derive the fixture file name from the request's Host, target and body.
fixtureKey :: ByteString -> Maybe FilePath
fixtureKey req = do
    let (headBytes, rest) = BS.breakSubstring "\r\n\r\n" req
        body = BS.drop 4 rest
        headers = mapMaybe splitHeader (drop 1 (BC.lines (BC.filter (/= '\r') headBytes)))
    host <- lookup "host" headers
    let service = BC.unpack (BC.takeWhile (/= '.') host)
    case lookup "x-amz-target" headers of
        Just target ->
            let op = BC.unpack (BC.drop 1 (BC.dropWhile (/= '.') target))
             in Just (service <> "." <> op <> ".json")
        Nothing -> do
            action <- listToMaybe (mapMaybe (BS.stripPrefix "Action=") (BC.split '&' body))
            Just (service <> "." <> BC.unpack action <> ".xml")

-- | Split @Name: value@ into a lower-cased name and a trimmed value.
splitHeader :: ByteString -> Maybe (ByteString, ByteString)
splitHeader line = case BC.break (== ':') line of
    (name, rest)
        | BS.null rest -> Nothing
        | otherwise -> Just (BC.map toLower name, BC.dropWhile (== ' ') (BS.drop 1 rest))

-- | Serialise a minimal HTTP/1.1 response that closes the connection.
httpResponse :: Int -> ByteString -> ByteString
httpResponse status body =
    BS.concat
        [ "HTTP/1.1 "
        , BC.pack (show status)
        , if status == 200 then " OK" else " Bad Request"
        , "\r\nContent-Length: "
        , BC.pack (show (BS.length body))
        , "\r\nConnection: close\r\n\r\n"
        , body
        ]
