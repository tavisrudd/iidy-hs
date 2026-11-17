{- | A fake network for HTTP import tests (card C15): an 'HttpSeam' whose
resolver answers from a table (numeric literals resolve with
@AI_NUMERICHOST@, so no DNS query is made) and whose connections serve
canned response bytes, so the real http-client request writer, response
parser and redirect logic run with no socket. It records every address
connected to and every raw request.
-}
module Test.FakeHttp (
    Reply (..),
    FakeNetwork (..),
    FakeNet (..),
    newFakeNet,
    fakeSeam,
    requestKey,
    v4,
) where

import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Network.Socket qualified as NS

import Iidy.Yaml.Imports.Loaders.HttpGuard (HttpSeam (..), RawIO (..), resolveHostWith)

-- | A canned response.
data Reply = Ok Text | Redirect Text

{- | The fake network's contents: successive resolver answers per host
name (the last one repeats), and replies by (Host header, path), where
the path @*@ matches any path on that host.
-}
data FakeNetwork = FakeNetwork
    { fwHosts :: [(String, [[NS.SockAddr]])]
    , fwReplies :: [((ByteString, ByteString), Reply)]
    }

-- | What one run of the fake saw.
data FakeNet = FakeNet
    { fnConnected :: !(IORef [NS.SockAddr])
    -- ^ addresses connected to, in order
    , fnRequests :: !(IORef [ByteString])
    -- ^ raw requests, in order
    , fnLookups :: !(IORef (Map String Int))
    -- ^ resolver lookups so far, per host name
    }

newFakeNet :: IO FakeNet
newFakeNet = FakeNet <$> newIORef [] <*> newIORef [] <*> newIORef Map.empty

-- | An IPv4 socket address on port 80.
v4 :: (Int, Int, Int, Int) -> NS.SockAddr
v4 (a, b, c, d) = NS.SockAddrInet 80 (NS.tupleToHostAddress (fromIntegral a, fromIntegral b, fromIntegral c, fromIntegral d))

fakeSeam :: FakeNetwork -> FakeNet -> HttpSeam
fakeSeam network net = HttpSeam{hsResolve = resolve, hsConnect = connect}
  where
    resolve :: String -> Int -> IO [NS.SockAddr]
    resolve h p = case lookup h (fwHosts network) of
        Just answers -> do
            n <- atomicModifyIORef' (fnLookups net) (\m -> (Map.insertWith (+) h 1 m, Map.findWithDefault 0 h m))
            pure (nthOrLast n answers)
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
                        pure (respond (fwReplies network) req)
                writeIORef pending (Just BS.empty)
                pure resp
        pure
            RawIO
                { rioRead = readChunk
                , rioWrite = \bs -> atomicModifyIORef' written (\acc -> (acc <> bs, ()))
                , rioClose = pure ()
                }

nthOrLast :: Int -> [[a]] -> [a]
nthOrLast n answers = case drop n answers of
    a : _ -> a
    [] -> concat (take 1 (reverse answers))

-- | The raw HTTP response for a raw HTTP request (direct or via a proxy).
respond :: [((ByteString, ByteString), Reply)] -> ByteString -> ByteString
respond replies req =
    let (h, path) = requestKey req
     in case lookup (h, path) replies <|> lookup (h, "*") replies of
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
        hostName hdr
            | "[" `BS.isPrefixOf` hdr = BC.takeWhile (/= ']') (BS.drop 1 hdr)
            | otherwise = BC.takeWhile (/= ':') hdr
     in (maybe "" hostName hostHeader, path)
