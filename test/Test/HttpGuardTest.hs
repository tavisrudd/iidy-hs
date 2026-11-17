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
import Data.IORef (readIORef)
import Data.Text (Text)
import Data.Text qualified as T
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
import Test.FakeHttp (FakeNet (..), FakeNetwork (..), Reply (..), fakeSeam, newFakeNet, requestKey, v4)
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
-- Fake network (see "Test.FakeHttp")
------------------------------------------------------------------------

publicAddr, proxyAddr, metadataAddr :: NS.SockAddr
publicAddr = v4 (203, 0, 113, 10)
proxyAddr = v4 (127, 0, 0, 1)
metadataAddr = v4 (169, 254, 169, 254)

{- | Host names the fake resolver knows (numeric literals resolve without
DNS), and the canned replies. @rebind.example@ answers a public address
first and loopback on every later lookup (DNS rebinding).
-}
network :: FakeNetwork
network =
    FakeNetwork
        { fwHosts =
            [ ("public.example", [[publicAddr]])
            , ("t.example.com", [[publicAddr]])
            , ("other.example", [[publicAddr]])
            , ("metadata.evil.example", [[metadataAddr]])
            , ("proxy.local", [[proxyAddr]])
            , ("rebind.example", [[publicAddr], [proxyAddr]])
            ]
        , fwReplies =
            [ (("public.example", "/ok.yaml"), Ok "a: 1\n")
            , (("public.example", "/r.yaml"), Redirect "http://169.254.169.254/latest/meta-data/")
            , (("t.example.com", "/a.yaml"), Redirect "http://t.example.com/b.yaml")
            , (("t.example.com", "/b.yaml"), Ok "b: 2\n")
            , (("t.example.com", "/out.yaml"), Redirect "http://other.example/c.yaml")
            , (("other.example", "/c.yaml"), Ok "c: 3\n")
            , (("127.0.0.1", "/x.yaml"), Ok "x: local\n")
            , (("rebind.example", "/ok.yaml"), Ok "r: 1\n")
            ]
        }

------------------------------------------------------------------------
-- Running an import through the real dispatcher
------------------------------------------------------------------------

fetch :: ImportPolicy -> ImportBase -> Text -> IO (FakeNet, Either ImportError ImportData)
fetch policy base loc = do
    net <- newFakeNet
    let cfg = (mkImportConfig Nothing policy){icHttpSeam = fakeSeam network net}
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
        settings <- guardManagerSettings (fakeSeam network net) guard (managerSetProxy (useProxy (Proxy "proxy.local" 3128)) Client.defaultManagerSettings)
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
        , ("fd00:ec2::23", True)
        , ("fd00:ec2:ffff::1", True)
        , ("fd00:ec3::254", False)
        , ("::ffff:127.0.0.1", True)
        , ("::ffff:203.0.113.10", False)
        , ("::127.0.0.1", True)
        , ("64:ff9b::a9fe:a9fe", True)
        , ("64:ff9b::cb00:710a", False)
        ]
    ]
