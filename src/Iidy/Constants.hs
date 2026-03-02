-- | Project-wide constants.
module Iidy.Constants
  ( -- * CFN polling
    defaultPollIntervalSecs
  , defaultPollTimeoutSecs
  , defaultPreviousEventsCount
  , maxChangesetCreationTimeoutSecs
  , changesetPollIntervalSecs
    -- * HTTP imports
  , httpTimeoutSeconds
  , httpMaxResponseBytes
    -- * Regex validation
  , maxRegexPatternLength
  ) where

------------------------------------------------------------------------
-- CFN polling
------------------------------------------------------------------------

defaultPollIntervalSecs :: Int
defaultPollIntervalSecs = 2

defaultPollTimeoutSecs :: Int
defaultPollTimeoutSecs = 3600

defaultPreviousEventsCount :: Int
defaultPreviousEventsCount = 10

maxChangesetCreationTimeoutSecs :: Int
maxChangesetCreationTimeoutSecs = 300

changesetPollIntervalSecs :: Int
changesetPollIntervalSecs = 2

------------------------------------------------------------------------
-- HTTP imports
------------------------------------------------------------------------

-- | HTTP response timeout in seconds.
httpTimeoutSeconds :: Int
httpTimeoutSeconds = 30

-- | Maximum HTTP response body size in bytes (10 MB).
httpMaxResponseBytes :: Int
httpMaxResponseBytes = 10 * 1024 * 1024

------------------------------------------------------------------------
-- Regex validation
------------------------------------------------------------------------

-- | Maximum regex pattern length for schema/param pattern validation.
-- regex-tdfa is NFA-based (no catastrophic backtracking), but we cap
-- pattern length as defense-in-depth against pathological compilation
-- cost on extremely long patterns.
maxRegexPatternLength :: Int
maxRegexPatternLength = 1024
