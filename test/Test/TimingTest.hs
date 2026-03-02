module Test.TimingTest (timingTests) where

import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Time (getCurrentTime, diffUTCTime)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime(..))
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Word (Word8, Word32)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool)

import Iidy.Aws.Timing
  ( TimeProvider(..)
  , systemTimeProvider
  , reliableTimeProvider
  , mockTimeProvider
  , parseNtpResponse
  , getWord32
  , ntpRequest
  , ntpTimeoutMicros
  )

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Convert a Word32 to 4 big-endian bytes.
toBigEndian :: Word32 -> [Word8]
toBigEndian w =
  [ fromIntegral ((w `shiftR` 24) .&. 0xFF)
  , fromIntegral ((w `shiftR` 16) .&. 0xFF)
  , fromIntegral ((w `shiftR`  8) .&. 0xFF)
  , fromIntegral  (w              .&. 0xFF)
  ]

-- | Build a 48-byte NTP response packet with given transmit timestamp.
-- Bytes 0-39 are zero (header), bytes 40-43 are NTP seconds (big-endian),
-- bytes 44-47 are NTP fraction (big-endian).
buildNtpPacket :: Word32 -> Word32 -> ByteString
buildNtpPacket secs frac =
  BS.pack $ replicate 40 0 ++ toBigEndian secs ++ toBigEndian frac

-- | NTP epoch offset: seconds between 1900-01-01 and 1970-01-01.
ntpUnixOffset :: Word32
ntpUnixOffset = 2208988800

-- | Known NTP timestamp for deterministic testing.
-- NTP seconds 3,917,000,000 → Unix seconds 1,708,011,200 → 2024-02-15 18:13:20 UTC
knownNtpSecs :: Word32
knownNtpSecs = 3917000000

knownExpectedTime :: UTCTime
knownExpectedTime =
  posixSecondsToUTCTime (realToFrac (fromIntegral (knownNtpSecs - ntpUnixOffset) :: Double))

------------------------------------------------------------------------
-- Test groups
------------------------------------------------------------------------

timingTests :: [TestTree]
timingTests =
  [ testGroup "NTP packet parsing" packetTests
  , testGroup "TimeProvider behavior" providerTests
  , testGroup "Constants" constantTests
  ]

------------------------------------------------------------------------
-- Packet parsing tests (pure functions, no IO)
------------------------------------------------------------------------

packetTests :: [TestTree]
packetTests =
  [ testCase "parseNtpResponse rejects empty packet" $
      parseNtpResponse BS.empty @?= Nothing

  , testCase "parseNtpResponse rejects short packet (47 bytes)" $
      parseNtpResponse (BS.replicate 47 0) @?= Nothing

  , testCase "parseNtpResponse accepts 48-byte all-zero packet" $
      assertBool "returns Just" (parseNtpResponse (BS.replicate 48 0) /= Nothing)

  , testCase "parseNtpResponse extracts known timestamp" $ do
      let pkt = buildNtpPacket knownNtpSecs 0
      case parseNtpResponse pkt of
        Nothing -> fail "Expected Just, got Nothing"
        Just t  -> t @?= knownExpectedTime

  , testCase "parseNtpResponse accepts packet longer than 48 bytes" $
      assertBool "returns Just" (parseNtpResponse (BS.replicate 64 0) /= Nothing)

  , testCase "getWord32 reads 1 big-endian at offset 0" $
      getWord32 "\x00\x00\x00\x01" 0 @?= (1 :: Word32)

  , testCase "getWord32 reads maxBound big-endian at offset 0" $
      getWord32 "\xFF\xFF\xFF\xFF" 0 @?= (maxBound :: Word32)

  , testCase "getWord32 reads 256 big-endian at offset 0" $
      getWord32 "\x00\x00\x01\x00" 0 @?= (256 :: Word32)

  , testCase "getWord32 reads from non-zero offset" $ do
      -- 8 bytes: first 4 are zero, last 4 are 0x00000001
      let bs = "\x00\x00\x00\x00\x00\x00\x00\x01"
      getWord32 bs 4 @?= (1 :: Word32)

  , testCase "ntpRequest length is 48 bytes" $
      BS.length ntpRequest @?= 48

  , testCase "ntpRequest first byte is 0x23 (LI=0, VN=4, Mode=3)" $
      BS.index ntpRequest 0 @?= 0x23

  , testCase "ntpRequest bytes 1-47 are all zero" $
      BS.all (== 0) (BS.drop 1 ntpRequest) @?= True
  ]

------------------------------------------------------------------------
-- TimeProvider behavior tests
------------------------------------------------------------------------

providerTests :: [TestTree]
providerTests =
  [ testCase "mockTimeProvider tpNow returns exact fixed time" $ do
      let fixedTime = UTCTime (fromGregorian 2026 2 22) (15 * 3600 + 30 * 60)
          tp        = mockTimeProvider fixedTime
      t <- tpNow tp
      t @?= fixedTime

  , testCase "mockTimeProvider tpStartTime is 500ms before tpNow" $ do
      let fixedTime = UTCTime (fromGregorian 2026 2 22) (15 * 3600 + 30 * 60)
          tp        = mockTimeProvider fixedTime
      st  <- tpStartTime tp
      now <- tpNow tp
      let diff = diffUTCTime now st
      assertBool "diff is ~500ms" (abs (diff - 0.5) < 0.001)

  , testCase "mockTimeProvider tpNow returns same value on repeated calls" $ do
      let fixedTime = UTCTime (fromGregorian 2026 2 22) (15 * 3600 + 30 * 60)
          tp        = mockTimeProvider fixedTime
      t1 <- tpNow tp
      t2 <- tpNow tp
      t1 @?= t2

  , testCase "systemTimeProvider tpNow is within current time bounds" $ do
      before <- getCurrentTime
      t      <- tpNow systemTimeProvider
      after  <- getCurrentTime
      assertBool "tpNow >= before" (t >= before)
      assertBool "tpNow <= after"  (t <= after)

  , testCase "systemTimeProvider tpStartTime < tpNow" $ do
      st <- tpStartTime systemTimeProvider
      t  <- tpNow systemTimeProvider
      assertBool "startTime < now" (st < t)

  , testCase "systemTimeProvider tpStartTime is approximately 500ms before tpNow" $ do
      -- tpStartTime = getCurrentTime - 500ms; tpNow = getCurrentTime (fresh call)
      -- so diff = (freshNow) - (previousNow - 500ms) ≈ 500ms + small delta
      st   <- tpStartTime systemTimeProvider
      t    <- tpNow systemTimeProvider
      let diff = diffUTCTime t st
      assertBool "diff >= 0.4s" (diff >= 0.4)
      assertBool "diff < 2.0s"  (diff < 2.0)

  , testCase "reliableTimeProvider tpNow is within 5s of system clock" $ do
      sysTime <- getCurrentTime
      t       <- tpNow reliableTimeProvider
      let diff = abs (diffUTCTime t sysTime)
      assertBool "within 5 seconds of system time" (diff < 5.0)

  , testCase "reliableTimeProvider tpStartTime < tpNow" $ do
      st <- tpStartTime reliableTimeProvider
      t  <- tpNow reliableTimeProvider
      assertBool "startTime < now" (st < t)
  ]

------------------------------------------------------------------------
-- Constant tests
------------------------------------------------------------------------

constantTests :: [TestTree]
constantTests =
  [ testCase "ntpTimeoutMicros equals 2_000_000 (2 seconds)" $
      ntpTimeoutMicros @?= 2000000
  ]
