-- | Interactive renderer for terminal output with colors, spinners, and timestamps.
--
-- Handles all console output formatting, including ANSI colors, column alignment,
-- spinner management, and section-based ordering for CloudFormation operations.
module Iidy.Output.Renderers.Interactive
  ( InteractiveRenderer(..)
  , InteractiveOptions(..)
  , defaultInteractiveOptions
  , plainInteractiveOptions
  , newInteractiveRenderer
  , newInteractiveRendererWithHandles
  , renderOutputData
    -- * Constants
  , column2Start
  , minStatusPadding
  , maxPadding
  , resourceTypePadding
  , defaultScreenWidth
    -- * Formatting helpers (exported for testing)
  , formatSectionHeading
  , formatSectionLabel
  , formatSectionEntry
  , formatLogicalId
  , formatTimestampText
  , renderTimestamp
  , styleMuted
  , calcPadding
  , padRight
  , prettyFormatTags
  , prettyFormatParameters
  , formatTokenSource
    -- * Spinner management
  , startSpinner
  , stopSpinner
  , formatTimingText
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Exception (mask_)
import Control.Monad (when, unless)
import Data.IORef
import Data.List (sortBy)
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Foldable (asum)
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime, diffUTCTime)
import System.IO (Handle, stdout, stderr, hFlush, hIsTerminalDevice)

import Iidy.Aws.ClientReqToken (TokenInfo(..), TokenSource(..), DerivedTokenInfo(..))
import Iidy.Cfn.Types (StackChangeType(..))
import Iidy.Output.Color
import Iidy.Output.Spinner
  ( Spinner, SpinnerStyle(..)
  , newSpinner, spinnerSetMessage
  , spinnerRender, spinnerFinishAndClear, spinnerIntervalMs
  )
import Iidy.Output.Terminal (TerminalCapabilities(..), detectCapabilities)
import Iidy.Output.Theme (ColorTheme(..), resolveTheme)
import Iidy.Output.Types

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
  { ioTheme            :: !ColorTheme
  , ioShowTimestamps   :: !Bool
  , ioEnableSpinners   :: !Bool
  , ioEnableAnsi       :: !Bool
  , ioTerminalWidth    :: !(Maybe Int)
  } deriving stock (Show, Eq)

defaultInteractiveOptions :: InteractiveOptions
defaultInteractiveOptions = InteractiveOptions
  { ioTheme          = ThemeAuto
  , ioShowTimestamps = True
  , ioEnableSpinners = True
  , ioEnableAnsi     = True
  , ioTerminalWidth  = Nothing
  }

plainInteractiveOptions :: InteractiveOptions
plainInteractiveOptions = InteractiveOptions
  { ioTheme          = ThemeAuto
  , ioShowTimestamps = True
  , ioEnableSpinners = False
  , ioEnableAnsi     = False
  , ioTerminalWidth  = Nothing
  }

------------------------------------------------------------------------
-- Renderer state
------------------------------------------------------------------------

data InteractiveRenderer = InteractiveRenderer
  { irStdout             :: !Handle
  , irStderr             :: !Handle
  , irTheme              :: !IidyTheme
  , irOptions            :: !InteractiveOptions
  , irTerminalWidth      :: !Int
  , irHasRenderedContent :: !(IORef Bool)
  , irSpinner            :: !(IORef (Maybe Spinner))
  , irSpinnerThread      :: !(IORef (Maybe ThreadId))
  , irTimingState        :: !(IORef (Maybe (UTCTime, Maybe UTCTime)))
    -- ^ (start_time, last_event_time) for elapsed time display
  , irTimingThread       :: !(IORef (Maybe ThreadId))
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
  hasRendered <- newIORef False
  spinnerRef <- newIORef Nothing
  spinnerThreadRef <- newIORef Nothing
  timingStateRef <- newIORef Nothing
  timingThreadRef <- newIORef Nothing
  pure InteractiveRenderer
    { irStdout             = hOut
    , irStderr             = hErr
    , irTheme              = theme
    , irOptions            = opts
    , irTerminalWidth      = width
    , irHasRenderedContent = hasRendered
    , irSpinner            = spinnerRef
    , irSpinnerThread      = spinnerThreadRef
    , irTimingState        = timingStateRef
    , irTimingThread       = timingThreadRef
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

-- | Start a spinner with a message. Creates a background tick thread
-- and a timing task that updates the spinner message with elapsed time.
startSpinner :: InteractiveRenderer -> Text -> IO ()
startSpinner r msg = do
  -- Only start if spinners are enabled and ANSI is available
  isTty <- hIsTerminalDevice (irStdout r)
  if not (ioEnableSpinners (irOptions r)) || not isTty
    then pure ()
    else do
      -- Stop any existing spinner first
      stopSpinner r
      sp <- newSpinner (irStdout r) SpinnerDots12
      spinnerSetMessage sp msg
      atomicWriteIORef (irSpinner r) (Just sp)
      -- Start background tick thread
      let colorCode = "\ESC[36;1m"  -- cyan bold for Dots/Dots12
          interval  = spinnerIntervalMs SpinnerDots12 * 1000  -- microseconds
      tid <- forkIO $ spinnerTickLoop sp colorCode interval
      atomicWriteIORef (irSpinnerThread r) (Just tid)
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
  mTid <- readIORef (irSpinnerThread r)
  case mTid of
    Just tid -> killThread tid
    Nothing  -> pure ()
  atomicWriteIORef (irSpinnerThread r) Nothing
  -- Clear spinner display
  mSp <- readIORef (irSpinner r)
  case mSp of
    Just sp -> spinnerFinishAndClear sp
    Nothing -> pure ()
  atomicWriteIORef (irSpinner r) Nothing

------------------------------------------------------------------------
-- Timing task (updates spinner message with elapsed time every 1s)
------------------------------------------------------------------------

-- | Format timing text matching Rust's display format.
-- "X seconds elapsed total." or "X seconds elapsed total. Y since last event."
formatTimingText :: Int -> Maybe Int -> Text
formatTimingText totalElapsed mSinceLastEvent =
  case mSinceLastEvent of
    Just sinceLastEvent ->
      T.pack (show totalElapsed) <> " seconds elapsed total. "
        <> T.pack (show sinceLastEvent) <> " since last event."
    Nothing ->
      T.pack (show totalElapsed) <> " seconds elapsed total."

-- | Start the background timing task that updates spinner message every second.
startTimingTask :: InteractiveRenderer -> IO ()
startTimingTask r = do
  now <- getCurrentTime
  atomicWriteIORef (irTimingState r) (Just (now, Nothing))
  mSp <- readIORef (irSpinner r)
  case mSp of
    Nothing -> pure ()
    Just sp -> do
      tid <- forkIO $ timingLoop r sp
      atomicWriteIORef (irTimingThread r) (Just tid)

-- | Background loop that updates spinner message with elapsed time every 1 second.
timingLoop :: InteractiveRenderer -> Spinner -> IO ()
timingLoop r sp = do
  threadDelay 1000000  -- 1 second
  now <- getCurrentTime
  mState <- readIORef (irTimingState r)
  case mState of
    Nothing -> pure ()  -- stopped
    Just (startTime, mLastEventTime) -> do
      let totalElapsed = floor (diffUTCTime now startTime) :: Int
          mSinceLastEvent = case mLastEventTime of
            Just lastTime -> Just (floor (diffUTCTime now lastTime) :: Int)
            Nothing       -> Nothing
          text = styleMuted r (formatTimingText totalElapsed mSinceLastEvent)
      spinnerSetMessage sp text
      timingLoop r sp

-- | Stop the timing task.
stopTimingTask :: InteractiveRenderer -> IO ()
stopTimingTask r = mask_ $ do
  mTid <- readIORef (irTimingThread r)
  case mTid of
    Just tid -> killThread tid
    Nothing  -> pure ()
  atomicWriteIORef (irTimingThread r) Nothing
  atomicWriteIORef (irTimingState r) Nothing

-- | Update the last event time for timing display.
updateLastEventTime :: InteractiveRenderer -> UTCTime -> IO ()
updateLastEventTime r eventTime = do
  mState <- readIORef (irTimingState r)
  case mState of
    Just (startTime, _) ->
      atomicWriteIORef (irTimingState r) (Just (startTime, Just eventTime))
    Nothing -> pure ()

------------------------------------------------------------------------
-- Main dispatch
------------------------------------------------------------------------

renderOutputData :: InteractiveRenderer -> OutputData -> IO ()
renderOutputData r od = do
  -- Clear spinner before rendering any output that isn't spinner-managed
  case od of
    OdNewStackEvents _  -> pure ()  -- manages its own spinner lifecycle
    OdPollingStarted _  -> pure ()  -- starts spinner
    OdTokenInfo _       -> pure ()  -- no-op
    _                   -> stopSpinner r
  case od of
    OdCommandMetadata meta         -> renderCommandMetadata r meta
    OdStackDefinition def showT    -> renderStackDefinition r def showT
    OdStackEvents evts             -> renderStackEvents r evts
    OdStackContents contents       -> renderStackContents r contents
    OdStatusUpdate upd             -> renderStatusUpdate r upd
    OdCommandResult res            -> renderCommandResult r res
    OdFinalCommandSummary summ     -> renderFinalCommandSummary r summ
    OdStackList lst                -> renderStackList r lst
    OdChangeSetResult cs           -> renderChangesetResult r cs
    OdStackDrift drift             -> renderStackDrift r drift
    OdError err                    -> renderError r err
    OdTokenInfo _                  -> pure ()
    OdNewStackEvents evts          -> renderNewStackEvents r evts
    OdOperationComplete info       -> renderOperationComplete r info
    OdInactivityTimeout info       -> renderInactivityTimeout r info
    OdConfirmationPrompt req       -> renderConfirmationPrompt r req
    OdStackChangeDetails details   -> renderStackChangeDetails r details
    OdStackAbsentInfo info         -> renderStackAbsentInfo r info
    OdCostEstimate est             -> renderCostEstimate r est
    OdStackTemplate tmpl           -> renderStackTemplate r tmpl
    OdApprovalRequestResult res    -> renderApprovalRequestResult r res
    OdTemplateValidation val       -> renderTemplateValidation r val
    OdApprovalStatus st            -> renderApprovalStatus r st
    OdTemplateDiff diff            -> renderTemplateDiff r diff
    OdApprovalResult res           -> renderApprovalResult r res
    OdPollingStarted msg           -> startSpinner r msg

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
formatSectionLabel r text = colorize (th r) (thMuted (th r)) text

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
  UserProvided       -> "user-provided"
  AutoGenerated      -> "auto-generated"
  Derived dti        -> "derived from " <> dtiFrom dti <> " at " <> dtiStep dti

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
          Nothing     -> []
        otherTags = sortBy (comparing fst)
          [(k, v) | (k, v) <- Map.toList tags, not (k `elem` envKeys)]
        otherFormatted = map (\(k, v) -> k <> "=" <> v) otherTags
        truncated = case maxTags of
          Nothing -> otherFormatted
          Just mx ->
            let remaining = mx - length envFormatted
            in if remaining <= 0
               then []
               else if remaining < length otherFormatted
                    then take (remaining - 1) otherFormatted <> ["..."]
                    else otherFormatted
    in T.intercalate ", " (envFormatted <> truncated)

-- | Pretty format parameters (sorted key=value)
prettyFormatParameters :: Map Text Text -> Text
prettyFormatParameters params
  | Map.null params = ""
  | otherwise = T.intercalate ", " $ map (\(k, v) -> k <> "=" <> v) $ sortBy (comparing fst) $ Map.toList params

------------------------------------------------------------------------
-- Rendering methods
------------------------------------------------------------------------

renderCommandMetadata :: InteractiveRenderer -> CommandMetadata -> IO ()
renderCommandMetadata r meta = do
  printSectionHeadingLn r "Command Metadata:"
  printSectionEntry r "iidy Environment:" (colorize (th r) (thPrimary (th r)) (cmEnvironment meta))
  printSectionEntry r "Region:" (colorize (th r) (thPrimary (th r)) (cmRegion meta))
  case cmProfile meta of
    Just p | not (T.null p) -> printSectionEntry r "Profile:" (colorize (th r) (thPrimary (th r)) p)
    _ -> pure ()
  let serviceRole = fromMaybe "None" (cmIamServiceRole meta)
  printSectionEntry r "IAM Service Role:" (colorize (th r) (thPrimary (th r)) serviceRole)
  printSectionEntry r "Current IAM Principal:" (colorize (th r) (thPrimary (th r)) (cmCurrentIamPrincipal meta))
  printSectionEntry r "Credential Source:" (styleMuted r (cmCredentialSource meta))
  printSectionEntry r "CLI Arguments:" (styleMuted r (prettyFormatParameters (cmCliArguments meta)))
  printSectionEntry r "iidy Version:" (styleMuted r (cmVersion meta))
  let tokenText = styleMuted r (tiValue (cmPrimaryToken meta))
        <> " " <> styleMuted r ("(" <> formatTokenSource (tiSource (cmPrimaryToken meta)) <> ")")
  printSectionEntry r "Client Req Token:" tokenText
  let derived = cmDerivedTokens meta
  unless (null derived) $ do
    printSectionEntry r "Derived Tokens:" (T.pack (show (length derived)) <> " tokens")
    mapM_ (\(i, tok) ->
      printSectionEntry r ("  [" <> T.pack (show i) <> "]")
        (styleMuted r (tiValue tok) <> " " <> styleMuted r ("(" <> formatTokenSource (tiSource tok) <> ")"))
      ) (zip [(1::Int)..] derived)

renderStackDefinition :: InteractiveRenderer -> StackDefinition -> Bool -> IO ()
renderStackDefinition r def showTimes = do
  printSectionHeadingLn r "Stack Details"
  -- Name (with StackSet if applicable)
  case Map.lookup "StackSetName" (sdTags def) of
    Just ssName -> printSectionEntry r "Name (StackSet):"
      (styleMuted r (sdName def) <> " " <> colorize (th r) (thPrimary (th r)) ssName)
    Nothing -> printSectionEntry r "Name:" (colorize (th r) (thPrimary (th r)) (sdName def))
  -- Description
  case sdDescription def of
    Just desc ->
      let descC = if T.isPrefixOf "StackSet" (sdName def)
                  then colorize (th r) (thPrimary (th r)) desc
                  else styleMuted r desc
      in printSectionEntry r "Description:" descC
    Nothing -> pure ()
  -- Status
  let statusDisplay = case sdStatusReason def of
        Just reason | not (T.null reason)
                    , T.isInfixOf "FAILED" (sdStatus def)
                      || sdStatus def == "ROLLBACK_COMPLETE"
                      || sdStatus def == "UPDATE_ROLLBACK_COMPLETE"
          -> colorizeResourceStatus (th r) (sdStatus def) <> " " <> styleMuted r reason
        _ -> colorizeResourceStatus (th r) (sdStatus def)
  printSectionEntry r "Status:" statusDisplay
  -- Capabilities
  let caps = if null (sdCapabilities def) then "None" else T.intercalate ", " (sdCapabilities def)
  printSectionEntry r "Capabilities:" (styleMuted r caps)
  -- Service Role
  printSectionEntry r "Service Role:" (styleMuted r (fromMaybe "None" (sdServiceRole def)))
  -- Region
  printSectionEntry r "Region:" (colorize (th r) (thPrimary (th r)) (sdRegion def))
  -- Tags
  printSectionEntry r "Tags:" (styleMuted r (prettyFormatTags (sdTags def) Nothing))
  -- Parameters
  printSectionEntry r "Parameters:" (styleMuted r (prettyFormatParameters (sdParameters def)))
  -- DisableRollback
  printSectionEntry r "DisableRollback:" (styleMuted r (boolText (sdDisableRollback def)))
  -- TerminationProtection
  let protText = styleMuted r (boolText (sdTerminationProtection def))
        <> if sdTerminationProtection def then " \128274" else ""  -- 🔒
  printSectionEntry r "TerminationProtection:" protText
  -- Times
  when showTimes $ do
    case sdCreationTime def of
      Just t -> printSectionEntry r "Creation Time:" (styleMuted r (renderTimestamp t))
      Nothing -> pure ()
    case sdLastUpdatedTime def of
      Just t -> printSectionEntry r "Last Update Time:" (styleMuted r (renderTimestamp t))
      Nothing -> pure ()
  -- Timeout
  case sdTimeoutInMinutes def of
    Just t -> printSectionEntry r "Timeout In Minutes:" (styleMuted r (T.pack (show t)))
    Nothing -> pure ()
  -- Notification ARNs
  let arns = if null (sdNotificationArns def) then "None" else T.intercalate ", " (sdNotificationArns def)
  printSectionEntry r "NotificationARNs:" (styleMuted r arns)
  -- Stack Policy
  case sdStackPolicy def of
    Just policy -> printSectionEntry r "Stack Policy Source:" (styleMuted r policy)
    Nothing -> pure ()
  -- ARN
  printSectionEntry r "ARN:" (styleMuted r (sdArn def))
  -- Console URL
  printSectionEntry r "Console URL:" (styleMuted r (sdConsoleUrl def))

renderStackEvents :: InteractiveRenderer -> StackEventsDisplay -> IO ()
renderStackEvents r evts = do
  -- Print section heading (use newline for multi-line sections)
  let isLive = T.isInfixOf "Live Stack Events" (sedTitle evts)
      hasEvents = not (null (sedEvents evts))
  if hasEvents || isLive
    then printSectionHeadingLn r (sedTitle evts)
    else printSectionHeading r (sedTitle evts)
  if null (sedEvents evts) && not isLive
    then rPutStrLn r (" " <> styleMuted r "No events found")
    else do
      let sorted = sortBy (comparing (seTimestamp . sewEvent)) (sedEvents evts)
          limited = case sedMaxEvents evts of
            Just mx -> take mx sorted
            Nothing -> sorted
          statusPad = calcPadding limited (seResourceStatus . sewEvent)
          rtypePad = calcPadding limited (seResourceType . sewEvent)
      mapM_ (renderSingleStackEvent r statusPad rtypePad) limited
      case sedTruncated evts of
        Just ti -> rPutStrLn r ("  " <> styleMuted r
          ("showing " <> T.pack (show (truncShown ti)) <> " of " <> T.pack (show (truncTotal ti)) <> " events"))
        Nothing -> pure ()

renderSingleStackEvent :: InteractiveRenderer -> Int -> Int -> StackEventWithTiming -> IO ()
renderSingleStackEvent r statusPad rtypePad ewt = do
  let event = sewEvent ewt
      ts = case seTimestamp event of
        Just t  -> formatTimestampText r (renderTimestamp t)
        Nothing -> formatTimestampText r (T.replicate 25 " ")
      -- Pad before coloring to avoid ANSI length issues
      statusPadded = padRight statusPad (seResourceStatus event)
      status = colorizeResourceStatus (th r) statusPadded
      rtypePadded = padRight rtypePad (seResourceType event)
      rtype = colorize (th r) (thInfo (th r)) rtypePadded
      logId = formatLogicalId r (seLogicalResourceId event)
      dur = case sewDurationSeconds ewt of
        Just d  -> " " <> styleMuted r ("(" <> T.pack (show d) <> "s)")
        Nothing -> ""
  rPutStrLn r (" " <> ts <> " " <> status <> " " <> rtype <> " " <> logId <> dur)
  -- Show failure reason on new line
  case seResourceStatusReason event of
    Just reason | not (T.null reason) && T.isInfixOf "FAILED" (seResourceStatus event) ->
      let cleaned = case T.breakOnEnd "Initiated" reason of
            (_, after) | not (T.null after) -> T.strip after
            _ -> T.strip reason
          maxW = irTerminalWidth r - 2
          -- Simple word wrap
          wrapped = wrapText maxW cleaned
      in mapM_ (\line -> rPutStrLn r ("  " <> colorize (th r) (thError (th r)) line)) wrapped
    _ -> pure ()

renderStackContents :: InteractiveRenderer -> StackContents -> IO ()
renderStackContents r contents = do
  -- Resources
  unless (null (scResources contents)) $ do
    printSectionHeadingLn r "Stack Resources"
    let idPad = calcPadding (scResources contents) sriLogicalResourceId
        rtypePad = calcPadding (scResources contents) sriResourceType
    mapM_ (\res ->
      rPutStrLn r (
        formatLogicalId r (padRight (idPad + 1) (" " <> sriLogicalResourceId res))
        <> " " <> styleMuted r (padRight rtypePad (sriResourceType res))
        <> " " <> styleMuted r (fromMaybe "" (sriPhysicalResourceId res))
      )) (scResources contents)
  -- Outputs
  if null (scOutputs contents)
    then do
      printSectionHeading r "Stack Outputs"
      rPutStrLn r (" " <> styleMuted r "None")
    else do
      printSectionHeadingLn r "Stack Outputs"
      let keyPad = calcPadding (scOutputs contents) soiOutputKey
      mapM_ (\out ->
        rPutStrLn r (
          formatLogicalId r (padRight (keyPad + 1) (" " <> soiOutputKey out))
          <> " " <> styleMuted r (soiOutputValue out)
        )) (scOutputs contents)
  -- Exports
  unless (null (scExports contents)) $ do
    let hasImports = any (not . null . seiImportingStacks) (scExports contents)
        isComplex = length (scExports contents) > 1 || hasImports
    if isComplex
      then printSectionHeadingLn r "Stack Exports"
      else printSectionHeading r "Stack Exports"
    let namePad = calcPadding (scExports contents) seiName
    mapM_ (\ex -> do
      rPutStrLn r (
        formatLogicalId r (padRight (namePad + 1) (" " <> seiName ex))
        <> " " <> styleMuted r (seiValue ex))
      mapM_ (\imp -> rPutStrLn r ("  " <> styleMuted r ("imported by " <> imp))) (seiImportingStacks ex)
      ) (scExports contents)
  -- Current Status
  printSectionHeading r "Current Stack Status"
  rPutStrLn r (" " <> colorizeResourceStatus (th r) (ssiStatus (scCurrentStatus contents))
    <> " " <> styleMuted r (fromMaybe "" (ssiStatusReason (scCurrentStatus contents))))
  -- Pending changesets
  unless (null (scPendingChangesets contents)) $ do
    printSectionHeadingLn r "Pending Changesets"
    mapM_ (\cs -> do
      let ctText = case csiCreationTime cs of
            Just t  -> formatTimestampText r (renderTimestamp t)
            Nothing -> "Unknown"
      printSectionEntry r ctText
        (colorize (th r) (thPrimary (th r)) (csiChangeSetName cs)
         <> " " <> csiStatus cs
         <> " " <> styleMuted r (fromMaybe "" (csiStatusReason cs)))
      case csiDescription cs of
        Just desc | not (T.null desc) -> do
          rPutStrLn r ("  Description: " <> styleMuted r desc)
          rPutStrLn r ""
        _ -> pure ()
      mapM_ (renderChangesetChange r) (csiChanges cs)
      rPutStrLn r ""
      ) (scPendingChangesets contents)

renderStatusUpdate :: InteractiveRenderer -> StatusUpdate -> IO ()
renderStatusUpdate r upd = do
  let tsText = if ioShowTimestamps (irOptions r)
               then formatTimestampText r (renderTimestamp (suTimestamp upd)) <> " "
               else ""
      msg = case suLevel upd of
        LevelError   -> colorize (th r) (thError (th r)) (suMessage upd)
        LevelWarning -> colorize (th r) (thWarning (th r)) (suMessage upd)
        LevelSuccess -> colorize (th r) (thSuccess (th r)) (suMessage upd)
        LevelInfo    -> suMessage upd
  rPutStrLn r (tsText <> msg)

renderCommandResult :: InteractiveRenderer -> CommandResult -> IO ()
renderCommandResult r res = do
  addContentSpacing r
  let statusText = if crSuccess res
                   then formatSectionHeading r "SUCCESS"
                   else colorize (th r) (thError (th r)) "FAILURE" <> ":"
  rPutStrLn r (statusText <> " (" <> T.pack (show (crElapsedSeconds res)) <> "s)")
  case crMessage res of
    Just msg -> rPutStrLn r msg
    Nothing  -> pure ()

renderFinalCommandSummary :: InteractiveRenderer -> FinalCommandSummary -> IO ()
renderFinalCommandSummary r summ = do
  addContentSpacing r
  let summaryText = case fcsResult summ of
        SummarySuccess ->
          if thColorsEnabled (th r)
          then colorizeOnBg (th r) AnsiBlack AnsiGreen "Success" <> " \128077"  -- 👍
          else "Success \128077"
        SummaryFailure ->
          if thColorsEnabled (th r)
          then colorizeOnBg (th r) AnsiWhite AnsiRed "Failure" <> " (\9583\176\9633\176\65289\9583\65077 \9531\9473\9531"  -- table flip
          else "Failure (\9583\176\9633\176\65289\9583\65077 \9531\9473\9531"
  printSectionEntry r "Command Summary:" summaryText
  case fcsResult summ of
    SummaryFailure -> rPutStrLn r "Fix and try again."
    _ -> pure ()

renderStackList :: InteractiveRenderer -> StackListDisplay -> IO ()
renderStackList r lst = do
  if null (sldStacks lst)
    then rPutStrLn r "No stacks found"
    else do
      let timePad = 24 :: Int
          statusPad = calcPadding (sldStacks lst) sleStackStatus
          header = padRight timePad "Creation/Update Time,"
                <> " " <> padRight statusPad "Status,"
                <> " " <> if sldShowTags lst then "Name, Tags" else "Name"
      rPutStrLn r (styleMuted r header)
      mapM_ (\stack -> do
        let lifecycleIcon
              | sleTerminationProtection stack
                || Map.lookup "lifetime" (sleTags stack) == Just "protected" = "\128274 "  -- 🔒
              | Map.lookup "lifetime" (sleTags stack) == Just "long" = "\8734 "   -- ∞
              | Map.lookup "lifetime" (sleTags stack) == Just "short" = "\9852 "  -- ♺
              | otherwise = ""
            baseStackName = if T.isPrefixOf "StackSet-" (sleStackName stack)
              then styleMuted r (sleStackName stack) <> " "
                   <> fromMaybe "Unknown stack set instance" (Map.lookup "StackSetName" (sleTags stack))
              else sleStackName stack
            envName = detectEnvironment (sleStackName stack) (sleTags stack)
            stackName = colorByEnvironment (th r) envName baseStackName
            tsText = case sleLastUpdatedTime stack of
              Just t -> padRight timePad (renderTimestamp t)
              Nothing -> case sleCreationTime stack of
                Just t  -> padRight timePad (renderTimestamp t)
                Nothing -> padRight timePad "Unknown"
            tagsDisplay = if sldShowTags lst
              then " " <> styleMuted r (prettyFormatTags (sleTags stack) (Just 3))
              else ""
            statusPadded = padRight statusPad (sleStackStatus stack)
            statusColored = colorizeResourceStatus (th r) statusPadded
        rPutStrLn r (formatTimestampText r tsText <> " " <> statusColored <> " "
                      <> styleMuted r lifecycleIcon <> stackName <> tagsDisplay)
        -- Show failure reason
        case sleStatusReason stack of
          Just reason | not (T.null reason)
                      , T.isInfixOf "FAILED" (sleStackStatus stack)
                        || sleStackStatus stack == "ROLLBACK_COMPLETE"
                        || sleStackStatus stack == "UPDATE_ROLLBACK_COMPLETE"
            -> rPutStrLn r ("  " <> styleMuted r reason)
          _ -> pure ()
        ) (sldStacks lst)

renderChangesetResult :: InteractiveRenderer -> ChangeSetCreationResult -> IO ()
renderChangesetResult r cs = do
  rPutStrLn r ""
  rPutStrLn r ("AWS Console URL for full changeset review: " <> styleMuted r (csrConsoleUrl cs))
  rPutStrLn r ""
  printSectionHeadingLn r "Pending Changesets"
  mapM_ (\changeset -> do
    let ctText = case csiCreationTime changeset of
          Just t  -> formatTimestampText r (renderTimestamp t)
          Nothing -> "Unknown time"
    printSectionEntry r ctText
      (colorize (th r) (thPrimary (th r)) (csiChangeSetName changeset) <> " " <> csiStatus changeset)
    mapM_ (renderChangesetChange r) (csiChanges changeset)
    ) (csrPendingChangesets cs)
  rPutStrLn r ""
  mapM_ (rPutStrLn r) (csrNextSteps cs)

renderChangesetChange :: InteractiveRenderer -> ChangeInfo -> IO ()
renderChangesetChange r change = do
  let actionW = 8 :: Int
      logIdW = 30 :: Int
  case ciAction change of
    "Add" -> do
      let actionPadded = padRight actionW (ciAction change)
      rPutStrLn r ("  " <> colorize (th r) (thSuccess (th r)) actionPadded
        <> " " <> padRight logIdW (ciLogicalResourceId change)
        <> " " <> styleMuted r (ciResourceType change))
    "Remove" -> do
      let resInfo = ciResourceType change <> maybe "" (" " <>) (ciPhysicalResourceId change)
          actionPadded = padRight actionW (ciAction change)
      rPutStrLn r ("  " <> colorize (th r) (thError (th r)) actionPadded
        <> " " <> padRight logIdW (ciLogicalResourceId change)
        <> " " <> styleMuted r resInfo)
    "Modify" -> do
      let (actionText, actionColor) = case ciReplacement change of
            Just "True"        -> ("Replace", thError (th r))
            Just "Conditional" -> ("Replace?", thError (th r))
            _                  -> ("Modify", thWarning (th r))
          resInfo = ciResourceType change <> maybe "" (" " <>) (ciPhysicalResourceId change)
      let showScope = case ciReplacement change of
            Just "True"        -> False
            Just "Conditional" -> False
            _                  -> True
      if showScope
        then do
          let scopeText = maybe "" (T.intercalate ", ") (ciScope change)
          rPutStrLn r ("  " <> colorize (th r) actionColor (padRight actionW actionText)
            <> " " <> padRight logIdW (ciLogicalResourceId change)
            <> " " <> colorize (th r) (thWarning (th r)) scopeText
            <> " " <> styleMuted r resInfo)
        else
          rPutStrLn r ("  " <> colorize (th r) actionColor (padRight actionW actionText)
            <> " " <> padRight logIdW (ciLogicalResourceId change)
            <> " " <> styleMuted r resInfo)
      -- Details
      mapM_ (\detail ->
        rPutStrLn r ("    " <> styleMuted r (cdTarget detail) <> ": "
          <> styleMuted r (fromMaybe "Unknown" (cdChangeSource detail)))
        ) (ciDetails change)
    _ -> do
      let actionPadded = padRight actionW (ciAction change)
      rPutStrLn r ("  " <> actionPadded
        <> " " <> padRight logIdW (ciLogicalResourceId change)
        <> " " <> styleMuted r (ciResourceType change))

renderStackDrift :: InteractiveRenderer -> StackDrift -> IO ()
renderStackDrift r drift = do
  if null (sdrDriftedResources drift)
    then rPutStrLn r "No drift detected. Stack resources are in sync with template."
    else do
      printSectionHeadingLn r "Drifted Resources"
      let idPad = maximum (0 : map (T.length . drLogicalResourceId) (sdrDriftedResources drift))
          typePad = maximum (0 : map (T.length . drResourceType) (sdrDriftedResources drift))
      mapM_ (\d -> do
        rPutStrLn r (" " <> colorize (th r) (thResourceId (th r)) (padRight idPad (drLogicalResourceId d))
          <> " " <> styleMuted r (padRight typePad (drResourceType d))
          <> " " <> styleMuted r (drPhysicalResourceId d))
        rPutStrLn r ("  " <> colorize (th r) (thError (th r)) (drDriftStatus d))
        mapM_ (\pd -> do
          rPutStrLn r ("   - property_path: " <> pdPropertyPath pd)
          case pdExpectedValue pd of
            Just v -> rPutStrLn r ("     expected_value: " <> v)
            Nothing -> pure ()
          case pdActualValue pd of
            Just v -> rPutStrLn r ("     actual_value: " <> v)
            Nothing -> pure ()
          case pdDifferenceType pd of
            Just v -> rPutStrLn r ("     difference_type: " <> v)
            Nothing -> pure ()
          ) (drPropertyDifferences d)
        ) (sdrDriftedResources drift)
  rPutStrLn r ""

renderError :: InteractiveRenderer -> ErrorInfo -> IO ()
renderError r err = do
  rPutStrLn r ""
  case eiErrorDetails err of
    ErrorStackAbsent ctx -> renderStackAbsentError r ctx
    ErrorGeneric details -> do
      rPutStrLn r (colorizeBold (th r) (thError (th r)) "ERROR"
        <> ": " <> colorizeBold (th r) (thError (th r)) (eiMessage err))
      case details of
        Just detailsText -> do
          rPutStrLn r ""
          rPutStrLn r detailsText
        Nothing -> pure ()
      mapM_ (\sug -> rPutStrLn r ("  \8226 " <> styleMuted r sug)) (eiSuggestions err)

renderNewStackEvents :: InteractiveRenderer -> [StackEventWithTiming] -> IO ()
renderNewStackEvents r events = do
  unless (null events) $ do
    -- Preserve timing start time across spinner restart
    preservedState <- readIORef (irTimingState r)
    stopSpinner r
    let statusPad = calcPadding events (seResourceStatus . sewEvent)
        rtypePad = calcPadding events (seResourceType . sewEvent)
    mapM_ (renderSingleStackEvent r statusPad rtypePad) events
    -- Restart spinner for continued polling
    startSpinner r "Loading live events..."
    -- Restore preserved start time and update last event time
    case preservedState of
      Just (startTime, _) -> do
        case NE.nonEmpty events of
          Just ne -> do
            let mLastEventTime = seTimestamp (sewEvent (NE.last ne))
            atomicWriteIORef (irTimingState r) (Just (startTime, mLastEventTime))
          Nothing -> pure ()
      Nothing -> pure ()

renderOperationComplete :: InteractiveRenderer -> OperationCompleteInfo -> IO ()
renderOperationComplete r info = do
  let msg = " " <> T.pack (show (ociElapsedSeconds info)) <> " seconds elapsed total."
  rPutStrLn r (styleMuted r msg)

renderInactivityTimeout :: InteractiveRenderer -> InactivityTimeoutInfo -> IO ()
renderInactivityTimeout r info = do
  let msg = " Inactivity timeout of " <> T.pack (show (itiTimeoutSeconds info)) <> " seconds reached. Stopping watch."
  rPutStrLn r (styleMuted r msg)

renderConfirmationPrompt :: InteractiveRenderer -> ConfirmationRequest -> IO ()
renderConfirmationPrompt r req = do
  isTty <- hIsTerminalDevice (irStdout r)
  if not isTty || not (ioEnableAnsi (irOptions r))
    then do
      rPutStrLn r ("CONFIRMATION REQUIRED: " <> cfrMessage req)
      rPutStrLn r "Use --yes flag to proceed automatically in non-interactive mode"
    else do
      rPutStr r ("? " <> colorizeBold (th r) (thError (th r)) (cfrMessage req) <> " (y/N) ")
      rFlush r
      -- Note: actual stdin reading is handled by the caller

renderStackChangeDetails :: InteractiveRenderer -> StackChangeDetails -> IO ()
renderStackChangeDetails r details = do
  case scdChangeType details of
    ChangeCreate ->
      rPutStrLn r (" " <> colorize (th r) (thInfo (th r)) "Creating new stack")
    ChangeUpdateWithChanges _ ->
      rPutStrLn r (" " <> colorize (th r) (thInfo (th r)) "Updating existing stack")
    ChangeUpdateNoChanges ->
      rPutStrLn r (" " <> colorize (th r) (thSuccess (th r)) "No changes detected so no stack update needed.")

renderStackAbsent :: InteractiveRenderer -> Text -> DynColor -> StackAbsentInfo -> IO ()
renderStackAbsent r label labelColor info = do
  let prefix = colorizeBold (th r) labelColor label
      sn = colorizeBold (th r) (thInfo (th r)) (saiStackName info)
  rPutStrLn r (prefix <> " The stack " <> sn <> " is absent")
  rPutStrLn r ("      env = " <> colorize (th r) (thPrimary (th r)) (saiEnvironment info))
  rPutStrLn r ("      region = " <> colorize (th r) (thPrimary (th r)) (saiRegion info))
  rPutStrLn r ("      account = " <> colorize (th r) (thPrimary (th r)) (saiAccount info))
  rPutStrLn r ("      auth_arn = " <> colorize (th r) (thPrimary (th r)) (saiAuthArn info) <> ".")

renderStackAbsentInfo :: InteractiveRenderer -> StackAbsentInfo -> IO ()
renderStackAbsentInfo r = renderStackAbsent r "info" (thSuccess (th r))

renderStackAbsentError :: InteractiveRenderer -> StackAbsentInfo -> IO ()
renderStackAbsentError r = renderStackAbsent r "ERROR" (thError (th r))

renderCostEstimate :: InteractiveRenderer -> CostEstimate -> IO ()
renderCostEstimate r est = do
  printSectionEntry r "Stack cost estimator:" (colorize (th r) (thPrimary (th r)) (ceiUrl (ceInfo est)))

renderStackTemplate :: InteractiveRenderer -> StackTemplate -> IO ()
renderStackTemplate r tmpl = do
  mapM_ (rPutStrLnErr r) (stStderrLines tmpl)
  rPutStrLn r (stTemplateBody tmpl)

renderApprovalRequestResult :: InteractiveRenderer -> ApprovalRequestResult -> IO ()
renderApprovalRequestResult r res = do
  if arrAlreadyApproved res
    then rPutStrLn r (colorize (th r) (thSuccess (th r)) "\128077 Your template has already been approved")
    else do
      printSectionHeadingLn r "Template Approval Request"
      rPutStrLn r ("Successfully uploaded template to: " <> styleMuted r (arrPendingLocation res))
      rPutStrLn r ""
      rPutStrLn r "Approve template with:"
      mapM_ (\step -> rPutStrLn r ("  " <> colorize (th r) (thPrimary (th r)) step)) (arrNextSteps res)

renderTemplateValidation :: InteractiveRenderer -> TemplateValidation -> IO ()
renderTemplateValidation r val = do
  when (tvEnabled val) $ do
    unless (null (tvErrors val)) $ do
      printSectionHeadingLn r "Template Validation Errors"
      mapM_ (\e -> rPutStrLn r (colorize (th r) (thError (th r)) "\10007"
        <> " " <> colorize (th r) (thError (th r)) e)) (tvErrors val)
    unless (null (tvWarnings val)) $ do
      printSectionHeadingLn r "Template Validation Warnings"
      mapM_ (\w -> rPutStrLn r (colorize (th r) (thWarning (th r)) "\9888"
        <> " " <> colorize (th r) (thWarning (th r)) w)) (tvWarnings val)
    when (null (tvErrors val) && null (tvWarnings val)) $
      rPutStrLn r (colorize (th r) (thSuccess (th r)) "\10003 Template validation passed")

renderApprovalStatus :: InteractiveRenderer -> ApprovalStatus -> IO ()
renderApprovalStatus r st = do
  if apsAlreadyApproved st
    then rPutStrLn r (colorize (th r) (thSuccess (th r)) "\128077 The template has already been approved")
    else do
      printSectionHeadingLn r "Approval Status"
      rPutStrLn r ("Pending template: " <> styleMuted r (apsPendingLocation st))
      case apsApprovedLocation st of
        Just loc -> rPutStrLn r ("Current approved: " <> styleMuted r loc)
        Nothing  -> rPutStrLn r "No previously approved template found"

renderTemplateDiff :: InteractiveRenderer -> TemplateDiff -> IO ()
renderTemplateDiff r diff = do
  if not (tdHasChanges diff)
    then rPutStrLn r (colorize (th r) (thSuccess (th r)) "Templates are identical")
    else do
      printSectionHeadingLn r "Template Changes"
      rPutStr r (tdDiffOutput diff)

renderApprovalResult :: InteractiveRenderer -> ApprovalResult -> IO ()
renderApprovalResult r res = do
  if arApproved res
    then do
      rPutStrLn r ""
      rPutStrLn r (colorize (th r) (thSuccess (th r)) "Template has been successfully approved!")
      case arApprovedLocation res of
        Just loc -> rPutStrLn r ("Approved template: " <> styleMuted r loc)
        Nothing  -> pure ()
    else rPutStrLn r (colorize (th r) (thWarning (th r)) "Approval cancelled")

------------------------------------------------------------------------
-- Utility helpers
------------------------------------------------------------------------

-- | Detect environment from stack name or tags
detectEnvironment :: Text -> Map Text Text -> Text
detectEnvironment stackName tags
  | T.isInfixOf "production"  stackName || envTagEquals "production"  = "production"
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
    go (w:ws) acc currentLen
      | null acc = go ws [w] (T.length w)
      | currentLen + 1 + T.length w > maxW =
          T.intercalate " " (reverse acc) : go (w:ws) [] 0
      | otherwise = go ws (w:acc) (currentLen + 1 + T.length w)

-- | Bool to Text
boolText :: Bool -> Text
boolText True  = "true"
boolText False = "false"
