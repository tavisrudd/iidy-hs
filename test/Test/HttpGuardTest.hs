{- | The HTTP import address filter and redirect rule (card C15).

Every case runs the real http-client request, response parser and
redirect logic over a fake network: an injected resolver and a
connection factory that serves canned response bytes, so no socket is
opened and no DNS query is made. The fake records every address it was
asked to connect to, so a test can show a blocked address was never
connected.
-}
module Test.HttpGuardTest (httpGuardTests) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client (Proxy (..), httpLbs, managerSetProxy, newManager, parseRequest, responseBody, useProxy)
import Network.HTTP.Client qualified as Client
import Network.Socket qualified as NS
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Control.Exception (try)
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..), mkFullDispatcher, mkImportConfig)
import Iidy.Yaml.Imports.Loaders.HttpGuard (
    GuardRefusal (..),
    HttpGuard (..),
    HttpSeam (..),
    RawIO (..),
    guardManagerSettings,
    isBlockedAddress,
    resolveHostWith,
 )
import Iidy.Yaml.Imports.Types (
    ImportBase,
    ImportData (..),
    ImportError (..),
    ImportPolicy,
    RemoteImports (..),
    childBase,
    importPolicy,
    rootBase,
 )
import Test.ImportFixtures (flagPolicy)

httpGuardTests :: [TestTree]
httpGuardTests =
    [ testGroup "untrusted requester" untrustedCases
    , testGroup "trusted requester" trustedCases
    , testGroup "redirects from a trusted prefix" redirectCases
    , testGroup "proxy" proxyCases
    , testGroup "real resolver on numeric literals (AI_NUMERICHOST)" numericCases
    , testGroup "isBlockedAddress" blockedCases
    ]

------------------------------------------------------------------------
-- Fake network
------------------------------------------------------------------------

-- | Canned responses by host and path.
data Reply = Ok Text | Redirect Text

-- | The fake's record of connections and requests.
data FakeNet = FakeNet
    { fnConnected :: !(IORef [NS.SockAddr])
    , fnRequests :: !(IORef [ByteString])
    , fnRebindLookups :: !(IORef Int)
    -- ^ lookups of @rebind.example@ so far
    }

v4 :: (Int, Int, Int, Int) -> NS.SockAddr
v4 (a, b, c, d) = NS.SockAddrInet 80 (NS.tupleToHostAddress (fromIntegral a, fromIntegral b, fromIntegral c, fromIntegral d))

publicAddr, proxyAddr, metadataAddr :: NS.SockAddr
publicAddr = v4 (203, 0, 113, 10)
proxyAddr = v4 (127, 0, 0, 1)
metadataAddr = v4 (169, 254, 169, 254)

-- | Host names the fake resolver knows; numeric literals resolve without DNS.
hostTable :: [(String, [NS.SockAddr])]
hostTable =
    [ ("public.example", [publicAddr])
    , ("t.example.com", [publicAddr])
    , ("other.example", [publicAddr])
    , ("metadata.evil.example", [metadataAddr])
    , ("proxy.local", [proxyAddr])
    ]

replies :: [((ByteString, ByteString), Reply)]
replies =
    [ (("public.example", "/ok.yaml"), Ok "a: 1\n")
    , (("public.example", "/r.yaml"), Redirect "http://169.254.169.254/latest/meta-data/")
    , (("t.example.com", "/a.yaml"), Redirect "http://t.example.com/b.yaml")
    , (("t.example.com", "/b.yaml"), Ok "b: 2\n")
    , (("t.example.com", "/out.yaml"), Redirect "http://other.example/c.yaml")
    , (("other.example", "/c.yaml"), Ok "c: 3\n")
    , (("127.0.0.1", "/x.yaml"), Ok "x: local\n")
    , (("rebind.example", "/ok.yaml"), Ok "r: 1\n")
    ]

newFakeNet :: IO FakeNet
newFakeNet = FakeNet <$> newIORef [] <*> newIORef [] <*> newIORef 0

fakeSeam :: FakeNet -> HttpSeam
fakeSeam net = HttpSeam{hsResolve = resolve, hsConnect = connect}
  where
    resolve :: String -> Int -> IO [NS.SockAddr]
    resolve h p
        | h == "rebind.example" = do
            -- first lookup public, every later one loopback (DNS rebinding)
            n <- atomicModifyIORef' (fnRebindLookups net) (\k -> (k + 1, k))
            pure [if n == 0 then publicAddr else proxyAddr]
        | otherwise = case lookup h hostTable of
            Just addrs -> pure addrs
            Nothing -> resolveHostWith [NS.AI_NUMERICHOST] h p
    connect :: NS.SockAddr -> IO RawIO
    connect addr = do
        atomicModifyIORef' (fnConnected net) (\as -> (as <> [addr], ()))
        written <- newIORef BS.empty
        pending <- newIORef Nothing
        let readChunk = do
                mResp <- readIORef pending
                resp <- case mResp of
                    Just r -> pure r
                    Nothing -> do
                        req <- readIORef written
                        atomicModifyIORef' (fnRequests net) (\rs -> (rs <> [req], ()))
                        pure (respond req)
                writeIORef pending (Just BS.empty)
                pure resp
        pure
            RawIO
                { rioRead = readChunk
                , rioWrite = \bs -> atomicModifyIORef' written (\acc -> (acc <> bs, ()))
                , rioClose = pure ()
                }

-- | The raw HTTP response for a raw HTTP request (direct or via a proxy).
respond :: ByteString -> ByteString
respond req = case lookup (requestKey req) replies of
    Just (Ok body) -> response "200 OK" [] (TE.encodeUtf8 body)
    Just (Redirect loc) -> response "302 Found" [("Location", TE.encodeUtf8 loc)] ""
    Nothing -> response "404 Not Found" [] "missing"
  where
    response :: ByteString -> [(ByteString, ByteString)] -> ByteString -> ByteString
    response status headers body =
        BS.concat $
            ["HTTP/1.1 ", status, "\r\nContent-Length: ", BC.pack (show (BS.length body)), "\r\nConnection: close\r\n"]
                <> concat [[k, ": ", v, "\r\n"] | (k, v) <- headers]
                <> ["\r\n", body]

-- | (Host header, path) of a request; a proxied request line carries the full URL.
requestKey :: ByteString -> (ByteString, ByteString)
requestKey req =
    let ls = BC.lines (BC.filter (/= '\r') req)
        target = case ls of
            l : _ -> BC.takeWhile (/= ' ') (BC.drop 1 (BC.dropWhile (/= ' ') l))
            [] -> ""
        path = case BC.breakSubstring "://" target of
            (_, rest) | not (BS.null rest) -> BC.dropWhile (/= '/') (BS.drop 3 rest)
            _direct -> target
        hostHeader = listToMaybe (mapMaybe (fmap (BC.dropWhile (== ' ')) . BS.stripPrefix "Host:") ls)
        hostName h
            | "[" `BS.isPrefixOf` h = BC.takeWhile (/= ']') (BS.drop 1 h)
            | otherwise = BC.takeWhile (/= ':') h
     in (maybe "" hostName hostHeader, path)

------------------------------------------------------------------------
-- Running an import through the real dispatcher
------------------------------------------------------------------------

fetch :: ImportPolicy -> ImportBase -> Text -> IO (FakeNet, Either ImportError ImportData)
fetch policy base loc = do
    net <- newFakeNet
    let cfg = (mkImportConfig Nothing policy){icHttpSeam = fakeSeam net}
    result <- mkFullDispatcher cfg loc base
    pure (net, result)

localRoot :: ImportBase
localRoot = rootBase "local.yaml"

-- | A remote document a local template imported.
untrustedDoc :: ImportBase
untrustedDoc = childBase localRoot "https://evil.example/u.yaml"

allowRemote :: ImportPolicy
allowRemote = importPolicy AllowRemoteImports

assertRefused :: Either ImportError ImportData -> IO ()
assertRefused = \case
    Left (ImportError e) -> assertBool ("expected a guard refusal, got: " <> T.unpack e) ("refused: " `T.isInfixOf` e)
    Right d -> assertFailure ("expected a refusal, got " <> show (idRawData d))

assertLoaded :: Text -> Either ImportError ImportData -> IO ()
assertLoaded raw = \case
    Left (ImportError e) -> assertFailure ("expected success, got: " <> T.unpack e)
    Right d -> idRawData d @?= raw

connectedTo :: FakeNet -> IO [NS.SockAddr]
connectedTo = readIORef . fnConnected

------------------------------------------------------------------------
-- Cases
------------------------------------------------------------------------

blockedLiterals :: [Text]
blockedLiterals =
    [ "http://127.0.0.1/x.yaml"
    , "http://[::1]/x.yaml"
    , "http://[::ffff:169.254.169.254]/latest/meta-data/"
    , "http://0.0.0.0/x.yaml"
    , "http://169.254.169.254/latest/meta-data/"
    , "http://metadata.evil.example/latest/meta-data/"
    ]

untrustedCases :: [TestTree]
untrustedCases =
    [ testCase (T.unpack loc) $ do
        (net, result) <- fetch allowRemote untrustedDoc loc
        assertRefused result
        connectedTo net >>= (@?= [])
    | loc <- blockedLiterals
    ]
        <> [ testCase "a public URL redirecting to the metadata address is refused" $ do
                (net, result) <- fetch allowRemote untrustedDoc "http://public.example/r.yaml"
                assertRefused result
                connected <- connectedTo net
                connected @?= [publicAddr]
                assertBool "no blocked address connected" (not (any isBlockedAddress connected))
           , testCase "a public URL loads, connected to the checked address" $ do
                (net, result) <- fetch allowRemote untrustedDoc "http://public.example/ok.yaml"
                assertLoaded "a: 1\n" result
                connectedTo net >>= (@?= [publicAddr])
           , testCase "a name re-resolving to loopback after the check connects to the checked address" $ do
                (net, result) <- fetch allowRemote untrustedDoc "http://rebind.example/ok.yaml"
                assertLoaded "r: 1\n" result
                connectedTo net >>= (@?= [publicAddr])
           , testCase "trust is not gained through the chain: trusted-prefix document under an untrusted one" $ do
                policy <- flagPolicy ["http://t.example.com/"]
                let laundered = childBase untrustedDoc "http://t.example.com/a.yaml"
                (net, result) <- fetch policy laundered "http://127.0.0.1/x.yaml"
                assertRefused result
                connectedTo net >>= (@?= [])
           ]

trustedCases :: [TestTree]
trustedCases =
    [ testCase "a local requester may reach loopback" $ do
        (net, result) <- fetch allowRemote localRoot "http://127.0.0.1/x.yaml"
        assertLoaded "x: local\n" result
        connectedTo net >>= (@?= [v4 (127, 0, 0, 1)])
    , testCase "a document under a flag-built trusted prefix may reach loopback" $ do
        policy <- flagPolicy ["http://t.example.com/"]
        (net, result) <- fetch policy (childBase localRoot "http://t.example.com/a.yaml") "http://127.0.0.1/x.yaml"
        assertLoaded "x: local\n" result
        connectedTo net >>= (@?= [v4 (127, 0, 0, 1)])
    ]

redirectCases :: [TestTree]
redirectCases =
    [ testCase "a redirect inside the trusted prefix is followed" $ do
        policy <- flagPolicy ["http://t.example.com/"]
        (_net, result) <- fetch policy localRoot "http://t.example.com/a.yaml"
        assertLoaded "b: 2\n" result
    , testCase "a redirect leaving the trusted prefixes is refused" $ do
        policy <- flagPolicy ["http://t.example.com/"]
        (net, result) <- fetch policy localRoot "http://t.example.com/out.yaml"
        assertRefused result
        requests <- readIORef (fnRequests net)
        map requestKey requests @?= [("t.example.com", "/out.yaml")]
    , testCase "without a trusted prefix, a local requester follows any redirect" $ do
        (_net, result) <- fetch allowRemote localRoot "http://t.example.com/out.yaml"
        assertLoaded "c: 3\n" result
    ]

{- | With a proxy, the target name is resolved and checked locally before
the request goes to the proxy, and the proxy itself (here on loopback) is
not filtered.
-}
proxyCases :: [TestTree]
proxyCases =
    [ testCase "a blocked target is refused before the proxy is contacted" $ do
        (net, result) <- viaProxy "http://metadata.evil.example/latest/meta-data/"
        case result of
            Left (GuardRefusal _) -> pure ()
            Right body -> assertFailure ("expected a refusal, got " <> show body)
        connectedTo net >>= (@?= [])
    , testCase "an allowed target goes to the (loopback) proxy" $ do
        (net, result) <- viaProxy "http://public.example/ok.yaml"
        case result of
            Left (GuardRefusal why) -> assertFailure ("refused: " <> T.unpack why)
            Right body -> body @?= "a: 1\n"
        connectedTo net >>= (@?= [proxyAddr])
    ]
  where
    viaProxy :: String -> IO (FakeNet, Either GuardRefusal ByteString)
    viaProxy url = do
        net <- newFakeNet
        let guard = HttpGuard{hgFilterAddresses = True, hgAllowedHop = Nothing, hgRequester = "https://evil.example/u.yaml"}
        settings <- guardManagerSettings (fakeSeam net) guard (managerSetProxy (useProxy (Proxy "proxy.local" 3128)) Client.defaultManagerSettings)
        mgr <- newManager settings
        req <- parseRequest url
        result <- try (BS.toStrict . responseBody <$> httpLbs req mgr)
        pure (net, result)

numericCases :: [TestTree]
numericCases =
    [ testCase lit $ do
        addrs <- resolveHostWith [NS.AI_NUMERICHOST] lit 80
        assertBool ("resolved: " <> show addrs) (not (null addrs))
        assertBool ("not all blocked: " <> show addrs) (all isBlockedAddress addrs)
    | lit <- ["2852039166", "0251.0376.0251.0376", "::ffff:a9fe:a9fe", "127.1", "0x7f000001"]
    ]

blockedCases :: [TestTree]
blockedCases =
    [ testCase (lit <> " -> " <> show expected) $ do
        addrs <- resolveHostWith [NS.AI_NUMERICHOST] lit 80
        case addrs of
            [addr] -> isBlockedAddress addr @?= expected
            other -> assertFailure ("expected one address, got " <> show other)
    | (lit, expected) <-
        [ ("203.0.113.10", False)
        , ("10.0.0.1", False)
        , ("127.0.0.53", True)
        , ("0.0.0.0", True)
        , ("169.254.0.1", True)
        , ("2001:db8::1", False)
        , ("::", True)
        , ("::1", True)
        , ("fe80::1", True)
        , ("febf::1", True)
        , ("fec0::1", False)
        , ("fd00:ec2::254", True)
        , ("::ffff:127.0.0.1", True)
        , ("::ffff:203.0.113.10", False)
        , ("::127.0.0.1", True)
        , ("64:ff9b::a9fe:a9fe", True)
        , ("64:ff9b::cb00:710a", False)
        ]
    ]
