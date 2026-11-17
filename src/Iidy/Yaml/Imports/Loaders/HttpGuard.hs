{- | Address filter and redirect rule for HTTP imports (card C15).

An HTTP import requested by an untrusted document ('isTrustedRequester')
may not reach loopback, link-local, unspecified or cloud instance-metadata
addresses. A request to a URL under a trusted prefix may only be
redirected to locations that are also trusted. Both checks run in
@managerModifyRequest@, which http-client calls on the first request and
on every redirect hop, so they use only the public http-client API.

For plain HTTP, the raw connection connects to the address the check
approved ('HttpSeam' 'hsConnect'), so a name cannot resolve differently
between the check and the connection. HTTPS keeps the TLS library's own
lookup (a DNS-rebinding window, limited by certificate validation for the
requested host name). With @HTTP_PROXY@ / @HTTPS_PROXY@ set, the target
host name is still resolved and checked locally before the request goes
to the proxy; the proxy itself is not filtered and may resolve the name
differently.
-}
module Iidy.Yaml.Imports.Loaders.HttpGuard (
    HttpSeam (..),
    RawIO (..),
    realHttpSeam,
    resolveHostWith,
    HttpGuard (..),
    httpGuardFor,
    GuardRefusal (..),
    isBlockedAddress,
    guardManagerSettings,
) where

import Control.Exception (Exception, IOException, bracketOnError, throwIO, try)
import Control.Monad (when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16, Word8)
import Network.HTTP.Client (ManagerSettings (..), Request, getUri, host, makeConnection, port, strippedHostName)
import Network.Socket qualified as NS
import Network.Socket.ByteString qualified as NSB

import Iidy.Yaml.Imports.Types (ImportBase (..), TrustedSources, isTrustedBase, isTrustedRequester)

------------------------------------------------------------------------
-- Seam
------------------------------------------------------------------------

{- | How HTTP imports resolve host names and open plain connections. The
real seam uses @getaddrinfo@ and @network@ sockets; tests inject a fake
resolver and a connection factory that serves canned bytes.
-}
data HttpSeam = HttpSeam
    { hsResolve :: String -> Int -> IO [NS.SockAddr]
    -- ^ host name (without IPv6 brackets) and port to addresses
    , hsConnect :: NS.SockAddr -> IO RawIO
    -- ^ open a plain connection to this address
    }

{- | A plain connection as read, write and close actions; http-client's
public 'makeConnection' turns it into a connection. A read returns an
empty string at end of input.
-}
data RawIO = RawIO
    { rioRead :: IO ByteString
    , rioWrite :: ByteString -> IO ()
    , rioClose :: IO ()
    }

realHttpSeam :: HttpSeam
realHttpSeam = HttpSeam{hsResolve = resolveHostWith [], hsConnect = connectTo}

{- | Resolve with @getaddrinfo@ and the given flags (tests pass
'NS.AI_NUMERICHOST' so no DNS query is made). A failure is no addresses.
-}
resolveHostWith :: [NS.AddrInfoFlag] -> String -> Int -> IO [NS.SockAddr]
resolveHostWith flags hostName portNum = do
    let hints = NS.defaultHints{NS.addrFlags = flags, NS.addrSocketType = NS.Stream}
    result <- try (NS.getAddrInfo (Just hints) (Just hostName) (Just (show portNum)))
    pure $ case result of
        Left (_ :: IOException) -> []
        Right infos -> List.nub (map NS.addrAddress infos)

connectTo :: NS.SockAddr -> IO RawIO
connectTo addr =
    bracketOnError (NS.socket (familyOf addr) NS.Stream NS.defaultProtocol) NS.close $ \sock -> do
        NS.connect sock addr
        pure RawIO{rioRead = NSB.recv sock 8192, rioWrite = NSB.sendAll sock, rioClose = NS.close sock}
  where
    familyOf :: NS.SockAddr -> NS.Family
    familyOf = \case
        NS.SockAddrInet{} -> NS.AF_INET
        NS.SockAddrInet6{} -> NS.AF_INET6
        NS.SockAddrUnix{} -> NS.AF_UNIX

------------------------------------------------------------------------
-- Guard
------------------------------------------------------------------------

-- | What to check for one HTTP import request.
data HttpGuard = HttpGuard
    { hgFilterAddresses :: !Bool
    -- ^ refuse blocked addresses (the requester is untrusted)
    , hgAllowedHop :: !(Maybe (Text -> Bool))
    -- ^ every hop's URL must satisfy this (a request under a trusted prefix)
    , hgRequester :: !Text
    -- ^ the requesting document, for messages
    }

{- | The guard for an HTTP import of @location@ requested from @base@: the
address filter applies when the requester chain is not trusted; a
request under a trusted prefix from a trusted requester may only be
redirected to trusted locations.
-}
httpGuardFor :: TrustedSources -> Text -> ImportBase -> HttpGuard
httpGuardFor trusted location base =
    HttpGuard
        { hgFilterAddresses = not requesterTrusted
        , hgAllowedHop =
            if requesterTrusted && isTrustedBase trusted location
                then Just (isTrustedBase trusted)
                else Nothing
        , hgRequester = requesterText
        }
  where
    requesterTrusted :: Bool
    requesterTrusted = isTrustedRequester trusted base
    requesterText :: Text
    requesterText = ibLocation base

-- | Why the guard refused a request.
newtype GuardRefusal = GuardRefusal Text
    deriving stock (Show)

instance Exception GuardRefusal

------------------------------------------------------------------------
-- Blocked addresses
------------------------------------------------------------------------

{- | Loopback, link-local (including the AWS metadata address
@169.254.169.254@), unspecified (@0.0.0.0/8@, @::@) and the AWS IPv6
link-service range @fd00:ec2::/32@ (instance metadata @fd00:ec2::254@,
the EKS Pod Identity Agent @fd00:ec2::23@), plus the IPv4 forms embedded in IPv6
(IPv4-mapped, IPv4-compatible and NAT64 @64:ff9b::/96@). Unix sockets are
refused too.
-}
isBlockedAddress :: NS.SockAddr -> Bool
isBlockedAddress = \case
    NS.SockAddrInet _ ha -> blockedV4 (NS.hostAddressToTuple ha)
    NS.SockAddrInet6 _ _ ha6 _ -> blockedV6 (NS.hostAddress6ToTuple ha6)
    NS.SockAddrUnix _ -> True

blockedV4 :: (Word8, Word8, Word8, Word8) -> Bool
blockedV4 (a, b, _, _) = a == 127 || a == 0 || (a == 169 && b == 254)

blockedV6 :: (Word16, Word16, Word16, Word16, Word16, Word16, Word16, Word16) -> Bool
blockedV6 (w0, w1, w2, w3, w4, w5, w6, w7)
    | all (== 0) [w0, w1, w2, w3, w4, w5, w6] && w7 <= 1 = True -- :: and ::1
    | w0 .&. 0xffc0 == 0xfe80 = True -- fe80::/10 link-local
    | (w0, w1) == (0xfd00, 0x0ec2) = True -- fd00:ec2::/32 AWS link services
    | all (== 0) [w0, w1, w2, w3, w4] && (w5 == 0xffff || w5 == 0) = embedded -- mapped / compatible
    | (w0, w1) == (0x0064, 0xff9b) && all (== 0) [w2, w3, w4, w5] = embedded -- NAT64
    | otherwise = False
  where
    embedded :: Bool
    embedded =
        blockedV4
            ( fromIntegral (w6 `div` 256)
            , fromIntegral (w6 `mod` 256)
            , fromIntegral (w7 `div` 256)
            , fromIntegral (w7 `mod` 256)
            )

------------------------------------------------------------------------
-- Manager settings
------------------------------------------------------------------------

{- | Wrap manager settings with the guard. @managerModifyRequest@ checks
every hop (redirect rule, then the address filter, remembering the
approved addresses per host); the raw connection connects plain HTTP to
an approved address, and any other host (a proxy, or a request that is
not filtered) through the seam without filtering.
-}
guardManagerSettings :: HttpSeam -> HttpGuard -> ManagerSettings -> IO ManagerSettings
guardManagerSettings seam guard base = do
    approved <- newIORef Map.empty
    pure
        base
            { managerModifyRequest = \req -> do
                req' <- managerModifyRequest base req
                checkHop seam guard approved req'
                pure req'
            , managerRawConnection =
                pure $ \_hostAddr hostName portNum -> do
                    raw <- rawConnect seam approved (strippedHostName hostName) portNum
                    makeConnection (rioRead raw) (rioWrite raw) (rioClose raw)
            }

checkHop :: HttpSeam -> HttpGuard -> IORef (Map (String, Int) [NS.SockAddr]) -> Request -> IO ()
checkHop seam guard approved req = do
    let url = T.pack (show (getUri req))
        hostName = strippedHostName (BC.unpack (host req))
        portNum = port req
    case hgAllowedHop guard of
        Just allowed
            | not (allowed url) ->
                refuse
                    ( "redirect to "
                        <> url
                        <> " leaves the trusted import sources (requested by "
                        <> hgRequester guard
                        <> ")"
                    )
        _allowed -> pure ()
    when (hgFilterAddresses guard) $ do
        -- http-client may run this more than once per hop; a host already
        -- approved keeps its checked addresses, so the check and the
        -- connection agree.
        known <- Map.lookup (hostName, portNum) <$> readIORef approved
        addrs <- maybe (hsResolve seam hostName portNum) pure known
        when (null addrs) $ refuse ("cannot resolve " <> T.pack hostName <> " for " <> url)
        case filter isBlockedAddress addrs of
            blocked : _ ->
                refuse
                    ( url
                        <> " resolves to "
                        <> T.pack (show blocked)
                        <> ": loopback, link-local and metadata addresses are not allowed"
                        <> " for imports requested by untrusted documents ("
                        <> hgRequester guard
                        <> "; to allow it, pass --trust-import-source with a prefix of that location)"
                    )
            [] -> atomicModifyIORef' approved (\m -> (Map.insert (hostName, portNum) addrs m, ()))
  where
    refuse :: Text -> IO ()
    refuse = throwIO . GuardRefusal

{- | Connect to the first approved address that accepts, or, for a host
the guard did not check, to the first resolved address that accepts.
-}
rawConnect :: HttpSeam -> IORef (Map (String, Int) [NS.SockAddr]) -> String -> Int -> IO RawIO
rawConnect seam approved hostName portNum = do
    known <- Map.lookup (hostName, portNum) <$> readIORef approved
    addrs <- maybe (hsResolve seam hostName portNum) pure known
    firstConnect addrs
  where
    firstConnect :: [NS.SockAddr] -> IO RawIO
    firstConnect = \case
        [] -> ioError (userError ("cannot resolve " <> hostName))
        [addr] -> hsConnect seam addr
        addr : rest -> do
            result <- try (hsConnect seam addr)
            case result of
                Right conn -> pure conn
                Left (_ :: IOException) -> firstConnect rest
