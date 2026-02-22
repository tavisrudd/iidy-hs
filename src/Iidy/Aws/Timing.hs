-- | Time provider for CloudFormation operations.
--
-- Uses system clock only (NTP feature dropped per workplan decision).
-- Provides start_time helper that subtracts 500ms for safe ordering.
module Iidy.Aws.Timing
  ( TimeProvider(..)
  , systemTimeProvider
  , mockTimeProvider
  ) where

import Data.Time (UTCTime, getCurrentTime, addUTCTime)

-- | Time provider abstraction for operations that need timestamps.
-- Uses system clock; NTP was dropped per workplan.
data TimeProvider = TimeProvider
  { tpNow       :: IO UTCTime
  , tpStartTime :: IO UTCTime  -- ^ now() - 500ms for safe ordering
  }

-- | System time provider (used for all operations)
systemTimeProvider :: TimeProvider
systemTimeProvider = TimeProvider
  { tpNow = getCurrentTime
  , tpStartTime = addUTCTime (-0.5) <$> getCurrentTime
  }

-- | Mock time provider for testing
mockTimeProvider :: UTCTime -> TimeProvider
mockTimeProvider fixedTime = TimeProvider
  { tpNow = pure fixedTime
  , tpStartTime = pure (addUTCTime (-0.5) fixedTime)
  }
