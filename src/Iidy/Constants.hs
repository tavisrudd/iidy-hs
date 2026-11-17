-- | Project-wide constants.
module Iidy.Constants (
    -- * CFN polling
    defaultPollIntervalSecs,
    defaultPollTimeoutSecs,
    defaultPreviousEventsCount,
    maxChangesetCreationTimeoutSecs,
    changesetPollIntervalSecs,

    -- * HTTP imports
    httpTimeoutSeconds,
    httpMaxResponseBytes,
    httpTotalTimeoutSeconds,

    -- * Resource limits (card C20)
    yamlMaxAliasNodes,
    yamlMaxExpandedBytes,
    importMaxDepth,
    importMaxTotal,
    helperMaxOutputChars,

    -- * Regex validation
    maxRegexPatternLength,
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

{- | Total time for one HTTP import, from request to the end of the body, in
seconds. Twice 'httpTimeoutSeconds', which covers only the wait for the
response headers: a server that sends headers and then drips the body would
otherwise hold the run indefinitely.
-}
httpTotalTimeoutSeconds :: Int
httpTotalTimeoutSeconds = 60

------------------------------------------------------------------------
-- Resource limits
------------------------------------------------------------------------

{- | Most nodes (scalars, sequences and mappings each count one) one YAML
document may hold after every alias is expanded. A few hundred bytes of
nested aliases otherwise expand exponentially; the largest document in the
repository holds far fewer nodes than this.
-}
yamlMaxAliasNodes :: Int
yamlMaxAliasNodes = 250000

{- | Most bytes of scalar text one YAML document may hold after every alias
is expanded (50 MiB). A few large anchored scalars repeated by aliases stay
under 'yamlMaxAliasNodes' yet expand to hundreds of megabytes; no deployable
template comes near this.
-}
yamlMaxExpandedBytes :: Int
yamlMaxExpandedBytes = 50 * 1024 * 1024

{- | Most nested imports on one chain (root document excluded). Real projects
nest a handful of levels; a server answering every URL with a document that
imports the next one otherwise runs until killed.
-}
importMaxDepth :: Int
importMaxDepth = 32

{- | Most imports resolved in one run (root document excluded), so a fan-out
cannot cause unbounded work either.
-}
importMaxTotal :: Int
importMaxTotal = 1000

{- | Longest result, in characters, of a single Handlebars helper (1 MiB, the
size of the largest deployable template). Checked on the result of every
helper; @pad@ and @replace@ also check before they build it.
-}
helperMaxOutputChars :: Int
helperMaxOutputChars = 1048576

------------------------------------------------------------------------
-- Regex validation
------------------------------------------------------------------------

{- | Maximum regex pattern length for schema/param pattern validation.
regex-tdfa is NFA-based (no catastrophic backtracking), but we cap
pattern length as defense-in-depth against pathological compilation
cost on extremely long patterns.
-}
maxRegexPatternLength :: Int
maxRegexPatternLength = 1024
