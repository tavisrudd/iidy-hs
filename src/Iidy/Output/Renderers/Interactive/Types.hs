{- | Shared types, formatting helpers, and spinner management for the interactive renderer.

This module contains the InteractiveRenderer data type, constructors, IO helpers,
formatting utilities, spinner/timing management, and pure utility functions.
Separated from the per-variant rendering functions (in Sections) to keep modules
within the 300-500 LOC guideline.
-}
module Iidy.Output.Renderers.Interactive.Types (
    -- * Types
    InteractiveRenderer (..),
    InteractiveOptions (..),

    -- * Constructors
    defaultInteractiveOptions,
    plainInteractiveOptions,
    newInteractiveRenderer,
    newInteractiveRendererWithHandles,

    -- * Constants
    column2Start,
    minStatusPadding,
    maxPadding,
    resourceTypePadding,
    defaultScreenWidth,

    -- * Formatting helpers
    th,
    formatSectionHeading,
    formatSectionLabel,
    formatSectionEntry,
    formatLogicalId,
    formatTimestampText,
    renderTimestamp,
    styleMuted,
    calcPadding,
    padRight,
    prettyFormatTags,
    prettyFormatParameters,
    formatTokenSource,

    -- * IO output helpers
    rPutStr,
    rPutStrLn,
    rFlush,
    rPutStrLnErr,
    printSectionHeading,
    printSectionHeadingLn,
    printSectionEntry,
    addContentSpacing,

    -- * Spinner management
    startSpinner,
    stopSpinner,
    formatTimingText,
    updateLastEventTime,

    -- * Utility helpers
    detectEnvironment,
    wrapText,
    boolText,
    shouldShowStatusReason,
) where

import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (mask_)
import Control.Monad (when)
import Data.Foldable (asum, for_)
import Data.IORef
import Data.List (sortBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, defaultTimeLocale, diffUTCTime, formatTime, getCurrentTime)
import System.IO (Handle, hFlush, hIsTerminalDevice, stderr, stdout)

import Iidy.Aws.ClientReqToken (DerivedTokenInfo (..), TokenSource (..))
import Iidy.Cfn.Status (StackStatus (..), isFailed)
import Iidy.Output.Color
import Iidy.Output.Spinner (
    Spinner,
    SpinnerStyle (..),
    newSpinner,
    spinnerFinishAndClear,
    spinnerIntervalMs,
    spinnerRender,
    spinnerSetMessage,
 )
import Iidy.Output.Terminal (TerminalCapabilities (..), detectCapabilities)
import Iidy.Output.Theme (ColorTheme (..), resolveTheme)

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

column2Start :: Int
column2Start = 25

minStatusPadding :: Int
minStatusPadding = 17

maxPadding :: Int
maxPadding = 60

resourceTypePadding :: Int
resourceTypePadding = 40

defaultScreenWidth :: Int
defaultScreenWidth = 130

------------------------------------------------------------------------
-- Options
------------------------------------------------------------------------

data InteractiveOptions = InteractiveOptions
    { ioTheme :: !ColorTheme
    , ioShowTimestamps :: !Bool
    , ioEnableSpinners :: !Bool
    , ioEnableAnsi :: !Bool
    , ioTerminalWidth :: !(Maybe Int)
    }
    deriving stock (Show, Eq)

defaultInteractiveOptions :: InteractiveOptions
defaultInteractiveOptions =
    InteractiveOptions
        { ioTheme = ThemeAuto
        , ioShowTimestamps = True
        , ioEnableSpinners = True
        , ioEnableAnsi = True
        , ioTerminalWidth = Nothing
        }

plainInteractiveOptions :: InteractiveOptions
plainInteractiveOptions =
    InteractiveOptions
        { ioTheme = ThemeAuto
        , ioShowTimestamps = True
        , ioEnableSpinners = False
        , ioEnableAnsi = False
        , ioTerminalWidth = Nothing
        }

------------------------------------------------------------------------
-- Renderer state
------------------------------------------------------------------------

data InteractiveRenderer = InteractiveRenderer
    { irStdout :: !Handle
    , irStderr :: !Handle
    , irTheme :: !IidyTheme
    , irOptions :: !InteractiveOptions
    , irTerminalWidth :: !Int
    , irIsTty :: !Bool
    , irHasRenderedContent :: !(IORef Bool)
    , irSpinner :: !(TVar (Maybe Spinner))
    , irSpinnerThread :: !(TVar (Maybe ThreadId))
    , irTimingState :: !(TVar (Maybe (UTCTime, Maybe UTCTime)))
    -- ^ (start_time, last_event_time) for elapsed time display
    , irTimingThread :: !(TVar (Maybe ThreadId))
    -- ^ Background thread updating spinner message with elapsed time
    }

newInteractiveRenderer :: InteractiveOptions -> IO InteractiveRenderer
newInteractiveRenderer = newInteractiveRendererWithHandles stdout stderr

newInteractiveRendererWithHandles :: Handle -> Handle -> InteractiveOptions -> IO InteractiveRenderer
newInteractiveRendererWithHandles hOut hErr opts = do
    caps <- detectCapabilities
    let colorsEnabled = ioEnableAnsi opts && tcHasColor caps
        theme = resolveTheme colorsEnabled (ioTheme opts)
        width = fromMaybe (fromMaybe defaultScreenWidth (tcWidth caps)) (ioTerminalWidth opts)
    isTty <- hIsTerminalDevice hOut
    hasRendered <- newIORef False
    spinnerRef <- newTVarIO Nothing
    spinnerThreadRef <- newTVarIO Nothing
    timingStateRef <- newTVarIO Nothing
    timingThreadRef <- newTVarIO Nothing
    pure
        InteractiveRenderer
            { irStdout = hOut
            , irStderr = hErr
            , irTheme = theme
            , irOptions = opts
            , irTerminalWidth = width
            , irIsTty = isTty
            , irHasRenderedContent = hasRendered
            , irSpinner = spinnerRef
            , irSpinnerThread = spinnerThreadRef
            , irTimingState = timingStateRef
            , irTimingThread = timingThreadRef
            }

------------------------------------------------------------------------
-- Internal output helpers (write to renderer's configured handles)
------------------------------------------------------------------------

rPutStrLn :: InteractiveRenderer -> Text -> IO ()
rPutStrLn r = TIO.hPutStrLn (irStdout r)

rPutStr :: InteractiveRenderer -> Text -> IO ()
rPutStr r = TIO.hPutStr (irStdout r)

rFlush :: InteractiveRenderer -> IO ()
rFlush r = hFlush (irStdout r)

rPutStrLnErr :: InteractiveRenderer -> Text -> IO ()
rPutStrLnErr r = TIO.hPutStrLn (irStderr r)

------------------------------------------------------------------------
-- Spinner management
------------------------------------------------------------------------

{- | Start a spinner with a message. Creates a background tick thread
and a timing task that updates the spinner message with elapsed time.
-}
startSpinner :: InteractiveRenderer -> Text -> IO ()
startSpinner r msg = do
    -- Only start if spinners are enabled and ANSI is available
    if not (ioEnableSpinners (irOptions r)) || not (irIsTty r)
        then pure ()
        else do
            -- Stop any existing spinner first
            stopSpinner r
            sp <- newSpinner (irStdout r) SpinnerDots12
            spinnerSetMessage sp msg
            atomically $ writeTVar (irSpinner r) (Just sp)
            -- Start background tick thread
            let colorCode = "\ESC[36;1m" -- cyan bold for Dots/Dots12
                interval = spinnerIntervalMs SpinnerDots12 * 1000 -- microseconds
            tid <- forkIO $ spinnerTickLoop sp colorCode interval
            atomically $ writeTVar (irSpinnerThread r) (Just tid)
            -- Start timing task
            startTimingTask r

-- | Background spinner tick loop
spinnerTickLoop :: Spinner -> Text -> Int -> IO ()
spinnerTickLoop sp colorCode interval = do
    spinnerRender sp colorCode
    threadDelay interval
    spinnerTickLoop sp colorCode interval

-- | Stop and clear the current spinner and timing task
stopSpinner :: InteractiveRenderer -> IO ()
stopSpinner r = mask_ $ do
    -- Stop timing task first
    stopTimingTask r
    -- Kill tick thread
    mTid <- readTVarIO (irSpinnerThread r)
    for_ mTid killThread
    atomically $ writeTVar (irSpinnerThread r) Nothing
    -- Clear spinner display
    mSp <- readTVarIO (irSpinner r)
    for_ mSp spinnerFinishAndClear
    atomically $ writeTVar (irSpinner r) Nothing

------------------------------------------------------------------------
-- Timing task (updates spinner message with elapsed time every 1s)
------------------------------------------------------------------------

{- | Format timing text matching Rust's display format.
"X seconds elapsed total." or "X seconds elapsed total. Y since last event."
-}
formatTimingText :: Int -> Maybe Int -> Text
formatTimingText totalElapsed mSinceLastEvent =
    case mSinceLastEvent of
        Just sinceLastEvent ->
            T.pack (show totalElapsed)
                <> " seconds elapsed total. "
                <> T.pack (show sinceLastEvent)
                <> " since last event."
        Nothing ->
            T.pack (show totalElapsed) <> " seconds elapsed total."

-- | Start the background timing task that updates spinner message every second.
startTimingTask :: InteractiveRenderer -> IO ()
startTimingTask r = do
    now <- getCurrentTime
    atomically $ writeTVar (irTimingState r) (Just (now, Nothing))
    mSp <- readTVarIO (irSpinner r)
    case mSp of
        Nothing -> pure ()
        Just sp -> do
            tid <- forkIO $ timingLoop r sp
            atomically $ writeTVar (irTimingThread r) (Just tid)

-- | Background loop that updates spinner message with elapsed time every 1 second.
timingLoop :: InteractiveRenderer -> Spinner -> IO ()
timingLoop r sp = do
    threadDelay 1000000 -- 1 second
    now <- getCurrentTime
    mState <- readTVarIO (irTimingState r)
    case mState of
        Nothing -> pure () -- stopped
        Just (startTime, mLastEventTime) -> do
            let totalElapsed = floor (diffUTCTime now startTime) :: Int
                mSinceLastEvent = case mLastEventTime of
                    Just lastTime -> Just (floor (diffUTCTime now lastTime) :: Int)
                    Nothing -> Nothing
                text = styleMuted r (formatTimingText totalElapsed mSinceLastEvent)
            spinnerSetMessage sp text
            timingLoop r sp

-- | Stop the timing task.
stopTimingTask :: InteractiveRenderer -> IO ()
stopTimingTask r = mask_ $ do
    mTid <- readTVarIO (irTimingThread r)
    for_ mTid killThread
    atomically $ writeTVar (irTimingThread r) Nothing
    atomically $ writeTVar (irTimingState r) Nothing

-- | Update the last event time for timing display.
updateLastEventTime :: InteractiveRenderer -> UTCTime -> IO ()
updateLastEventTime r eventTime = do
    mState <- readTVarIO (irTimingState r)
    case mState of
        Just (startTime, _) ->
            atomically $ writeTVar (irTimingState r) (Just (startTime, Just eventTime))
        Nothing -> pure ()

------------------------------------------------------------------------
-- Formatting helpers
------------------------------------------------------------------------

th :: InteractiveRenderer -> IidyTheme
th = irTheme

-- | Format section heading with bold + color
formatSectionHeading :: InteractiveRenderer -> Text -> Text
formatSectionHeading r text =
    let clean = fromMaybe text (T.stripSuffix ":" text)
     in colorizeBold (th r) (thSectionHeading (th r)) clean <> ":"

-- | Print section heading (without trailing newline)
printSectionHeading :: InteractiveRenderer -> Text -> IO ()
printSectionHeading r text = do
    hasContent <- readIORef (irHasRenderedContent r)
    when hasContent $ rPutStrLn r ""
    rPutStr r (formatSectionHeading r text)
    writeIORef (irHasRenderedContent r) True
    rFlush r

-- | Print section heading with newline
printSectionHeadingLn :: InteractiveRenderer -> Text -> IO ()
printSectionHeadingLn r text = do
    printSectionHeading r text
    rPutStrLn r ""

-- | Format a section label (muted color)
formatSectionLabel :: InteractiveRenderer -> Text -> Text
formatSectionLabel r = colorize (th r) (thMuted (th r))

-- | Format a section entry: " label           value\n"
formatSectionEntry :: InteractiveRenderer -> Text -> Text -> Text
formatSectionEntry r label value =
    " " <> formatSectionLabel r (padRight (column2Start - 1) label <> " ") <> value <> "\n"

-- | Print section entry
printSectionEntry :: InteractiveRenderer -> Text -> Text -> IO ()
printSectionEntry r label value = do
    rPutStr r (formatSectionEntry r label value)
    rFlush r

-- | Add content spacing (blank line before new content)
addContentSpacing :: InteractiveRenderer -> IO ()
addContentSpacing r = do
    hasContent <- readIORef (irHasRenderedContent r)
    when hasContent $ rPutStrLn r ""
    writeIORef (irHasRenderedContent r) True

-- | Pad text right to given width
padRight :: Int -> Text -> Text
padRight w t
    | T.length t >= w = t
    | otherwise = t <> T.replicate (w - T.length t) " "

-- | Format a logical resource ID
formatLogicalId :: InteractiveRenderer -> Text -> Text
formatLogicalId r = colorize (th r) (thResourceId (th r))

-- | Format a timestamp string
formatTimestampText :: InteractiveRenderer -> Text -> Text
formatTimestampText r = colorize (th r) (thTimestamp (th r))

-- | Render a UTCTime to canonical format
renderTimestamp :: UTCTime -> Text
renderTimestamp = T.pack . formatTime defaultTimeLocale "%a %b %d %Y %H:%M:%S"

-- | Style text as muted
styleMuted :: InteractiveRenderer -> Text -> Text
styleMuted r = colorize (th r) (thMuted (th r))

-- | Calculate padding for a collection
calcPadding :: [a] -> (a -> Text) -> Int
calcPadding items extractor =
    let maxLen = maximum (0 : map (T.length . extractor) items)
     in min maxPadding (max minStatusPadding maxLen)

-- | Format token source
formatTokenSource :: TokenSource -> Text
formatTokenSource = \case
    UserProvided -> "user-provided"
    AutoGenerated -> "auto-generated"
    Derived dti -> "derived from " <> dtiFrom dti <> " at " <> dtiStep dti

------------------------------------------------------------------------
-- Tag/parameter formatting
------------------------------------------------------------------------

-- | Pretty format tags with optional truncation, Environment tag first
prettyFormatTags :: Map Text Text -> Maybe Int -> Text
prettyFormatTags tags maxTags
    | Map.null tags = ""
    | otherwise =
        let envKeys = ["Environment", "environment", "ENVIRONMENT", "env", "ENV"] :: [Text]
            envTag = asum (map (\k -> (k,) <$> Map.lookup k tags) envKeys)
            envFormatted = case envTag of
                Just (k, v) -> [k <> "=" <> v]
                Nothing -> []
            otherTags =
                sortBy
                    (comparing fst)
                    [(k, v) | (k, v) <- Map.toList tags, k `notElem` envKeys]
            otherFormatted = map (\(k, v) -> k <> "=" <> v) otherTags
            truncated = case maxTags of
                Nothing -> otherFormatted
                Just mx ->
                    let remaining = mx - length envFormatted
                     in if remaining <= 0
                            then []
                            else
                                if remaining < length otherFormatted
                                    then take (remaining - 1) otherFormatted <> ["..."]
                                    else otherFormatted
         in T.intercalate ", " (envFormatted <> truncated)

-- | Pretty format parameters (sorted key=value)
prettyFormatParameters :: Map Text Text -> Text
prettyFormatParameters params
    | Map.null params = ""
    | otherwise = T.intercalate ", " $ map (\(k, v) -> k <> "=" <> v) $ sortBy (comparing fst) $ Map.toList params

------------------------------------------------------------------------
-- Status predicates
------------------------------------------------------------------------

-- | Whether a stack status warrants displaying its reason
shouldShowStatusReason :: StackStatus -> Bool
shouldShowStatusReason status =
    isFailed status
        || status == RollbackComplete
        || status == UpdateRollbackComplete

------------------------------------------------------------------------
-- Utility helpers
------------------------------------------------------------------------

-- | Detect environment from stack name or tags
detectEnvironment :: Text -> Map Text Text -> Text
detectEnvironment stackName tags
    | T.isInfixOf "production" stackName || envTagEquals "production" = "production"
    | T.isInfixOf "integration" stackName || envTagEquals "integration" = "integration"
    | T.isInfixOf "development" stackName || envTagEquals "development" = "development"
    | otherwise = ""
  where
    envTagEquals val =
        let envKeys = ["Environment", "environment", "ENVIRONMENT", "env", "ENV"]
         in any (\k -> fmap T.toLower (Map.lookup k tags) == Just val) envKeys

-- | Simple text wrapping at word boundaries
wrapText :: Int -> Text -> [Text]
wrapText maxW txt
    | T.length txt <= maxW = [txt]
    | otherwise = go (T.words txt) [] 0
  where
    go [] acc _ = [T.intercalate " " (reverse acc) | not (null acc)]
    go (w : ws) acc currentLen
        | null acc = go ws [w] (T.length w)
        | currentLen + 1 + T.length w > maxW =
            T.intercalate " " (reverse acc) : go (w : ws) [] 0
        | otherwise = go ws (w : acc) (currentLen + 1 + T.length w)

-- | Bool to Text
boolText :: Bool -> Text
boolText True = "true"
boolText False = "false"
