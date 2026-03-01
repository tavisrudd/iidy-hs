-- | Time provider for CloudFormation operations.
--
-- Specification: RFC 4330 - SNTP Version 4 (https://datatracker.ietf.org/doc/html/rfc4330)
-- Implements a minimal SNTP client for NTP time synchronization used to
-- detect clock drift in CI environments where system time may be unreliable.
--
-- Supports NTP-synchronized time for write operations (create, update, delete)
-- and plain system time for read-only operations. NTP addresses clock drift
-- during long-running CloudFormation operations.
module Iidy.Aws.Timing
  ( TimeProvider(..)
  , systemTimeProvider
  , reliableTimeProvider
  , mockTimeProvider
  ) where

import Control.Exception (SomeException, bracket, catch)
import Data.Bits (shiftL)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Time (UTCTime, getCurrentTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Word (Word8, Word32)
import Network.Socket
    ( AddrInfo(..), SocketType(Datagram)
    , getAddrInfo, defaultHints, addrSocketType
    , socket, addrFamily, addrProtocol, connect, addrAddress, close
    )
import Network.Socket.ByteString (send, recv)
import System.Timeout (timeout)

-- | Time provider abstraction for operations that need timestamps.
data TimeProvider = TimeProvider
  { tpNow       :: IO UTCTime
  , tpStartTime :: IO UTCTime  -- ^ now() - 500ms for safe ordering
  }

-- | System time provider for read-only operations. No network calls.
systemTimeProvider :: TimeProvider
systemTimeProvider = TimeProvider
  { tpNow = getCurrentTime
  , tpStartTime = addUTCTime (-0.5) <$> getCurrentTime
  }

-- | Reliable time provider that tries NTP with fallback to system time.
-- Attempts NTP twice (with 2-second timeout each), then falls back to system clock.
-- Used for write operations where timing precision matters.
reliableTimeProvider :: TimeProvider
reliableTimeProvider = TimeProvider
  { tpNow = reliableNow
  , tpStartTime = addUTCTime (-0.5) <$> reliableNow
  }

-- | Try NTP twice, fall back to system time.
reliableNow :: IO UTCTime
reliableNow = do
  r1 <- tryNtp
  case r1 of
    Just t  -> pure t
    Nothing -> do
      r2 <- tryNtp
      case r2 of
        Just t  -> pure t
        Nothing -> getCurrentTime

-- | Attempt a single NTP query with 2-second timeout.
tryNtp :: IO (Maybe UTCTime)
tryNtp =
  (timeout ntpTimeoutMicros queryNtp >>= \case
    Just (Just t) -> pure (Just t)
    _             -> pure Nothing
  ) `catch` \(_ :: SomeException) -> pure Nothing

ntpTimeoutMicros :: Int
ntpTimeoutMicros = 2_000_000  -- 2 seconds

-- | Query pool.ntp.org via SNTP (RFC 4330).
-- Sends a minimal 48-byte NTP request, extracts the transmit timestamp.
queryNtp :: IO (Maybe UTCTime)
queryNtp = do
  let hints = defaultHints { addrSocketType = Datagram }
  addrs <- getAddrInfo (Just hints) (Just "pool.ntp.org") (Just "123")
  case addrs of
    []    -> pure Nothing
    (a:_) ->
      bracket
        (socket (addrFamily a) (addrSocketType a) (addrProtocol a))
        close
        (\sock -> do
          connect sock (addrAddress a)
          _ <- send sock ntpRequest
          resp <- recv sock 48
          pure (parseNtpResponse resp)
        )

-- | Build a minimal SNTP request packet (48 bytes).
-- LI=0, Version=4, Mode=3 (client) → first byte = 0x23
ntpRequest :: ByteString
ntpRequest = BS.pack (0x23 : replicate 47 0)

-- | Parse the transmit timestamp from an NTP response.
-- Transmit timestamp is at bytes 40-47: 4 bytes seconds + 4 bytes fraction.
-- NTP epoch is 1900-01-01; Unix epoch is 1970-01-01 (offset = 2208988800).
parseNtpResponse :: ByteString -> Maybe UTCTime
parseNtpResponse bs
  | BS.length bs < 48 = Nothing
  | otherwise =
      let secs = getWord32 bs 40
          frac = getWord32 bs 44
          -- NTP epoch offset: seconds between 1900-01-01 and 1970-01-01
          ntpToUnixOffset :: Word32
          ntpToUnixOffset = 2208988800
          unixSecs = fromIntegral (secs - ntpToUnixOffset) :: Double
          fracSecs = fromIntegral frac / fromIntegral (maxBound :: Word32) :: Double
          posixTime = realToFrac (unixSecs + fracSecs)
      in Just (posixSecondsToUTCTime posixTime)

-- | Read a big-endian Word32 from a ByteString at the given offset.
getWord32 :: ByteString -> Int -> Word32
getWord32 bs off =
  (fromByte (BS.index bs off)       `shiftL` 24) +
  (fromByte (BS.index bs (off + 1)) `shiftL` 16) +
  (fromByte (BS.index bs (off + 2)) `shiftL`  8) +
   fromByte (BS.index bs (off + 3))
  where
    fromByte :: Word8 -> Word32
    fromByte = fromIntegral

-- | Mock time provider for testing.
mockTimeProvider :: UTCTime -> TimeProvider
mockTimeProvider fixedTime = TimeProvider
  { tpNow = pure fixedTime
  , tpStartTime = pure (addUTCTime (-0.5) fixedTime)
  }
