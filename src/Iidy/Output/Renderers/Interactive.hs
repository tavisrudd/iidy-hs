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
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Data.IORef
import Data.List (sortBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import System.IO (stdout, hFlush, hIsTerminalDevice, stderr)

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
  { irTheme              :: !IidyTheme
  , irOptions            :: !InteractiveOptions
  , irTerminalWidth      :: !Int
  , irHasRenderedContent :: !(IORef Bool)
  , irSpinner            :: !(IORef (Maybe Spinner))
  , irSpinnerThread      :: !(IORef (Maybe ThreadId))
  }

newInteractiveRenderer :: InteractiveOptions -> IO InteractiveRenderer
newInteractiveRenderer opts = do
  caps <- detectCapabilities
  let colorsEnabled = ioEnableAnsi opts && tcHasColor caps
      theme = resolveTheme colorsEnabled (ioTheme opts)
      width = fromMaybe (fromMaybe defaultScreenWidth (tcWidth caps)) (ioTerminalWidth opts)
  hasRendered <- newIORef False
  spinnerRef <- newIORef Nothing
  spinnerThreadRef <- newIORef Nothing
  pure InteractiveRenderer
    { irTheme              = theme
    , irOptions            = opts
    , irTerminalWidth      = width
    , irHasRenderedContent = hasRendered
    , irSpinner            = spinnerRef
    , irSpinnerThread      = spinnerThreadRef
    }

------------------------------------------------------------------------
-- Spinner management
------------------------------------------------------------------------

-- | Start a spinner with a message. Creates a background tick thread.
startSpinner :: InteractiveRenderer -> Text -> IO ()
startSpinner r msg = do
  -- Only start if spinners are enabled and ANSI is available
  isTty <- hIsTerminalDevice stdout
  if not (ioEnableSpinners (irOptions r)) || not isTty
    then pure ()
    else do
      -- Stop any existing spinner first
      stopSpinner r
      sp <- newSpinner SpinnerDots12
      spinnerSetMessage sp msg
      writeIORef (irSpinner r) (Just sp)
      -- Start background tick thread
      let colorCode = "\ESC[36;1m"  -- cyan bold for Dots/Dots12
          interval  = spinnerIntervalMs SpinnerDots12 * 1000  -- microseconds
      tid <- forkIO $ spinnerTickLoop sp colorCode interval
      writeIORef (irSpinnerThread r) (Just tid)

-- | Background spinner tick loop
spinnerTickLoop :: Spinner -> Text -> Int -> IO ()
spinnerTickLoop sp colorCode interval = do
  spinnerRender sp colorCode
  threadDelay interval
  spinnerTickLoop sp colorCode interval

-- | Stop and clear the current spinner
stopSpinner :: InteractiveRenderer -> IO ()
stopSpinner r = do
  -- Kill tick thread
  mTid <- readIORef (irSpinnerThread r)
  case mTid of
    Just tid -> killThread tid
    Nothing  -> pure ()
  writeIORef (irSpinnerThread r) Nothing
  -- Clear spinner display
  mSp <- readIORef (irSpinner r)
  case mSp of
    Just sp -> spinnerFinishAndClear sp
    Nothing -> pure ()
  writeIORef (irSpinner r) Nothing

------------------------------------------------------------------------
-- Main dispatch
------------------------------------------------------------------------

renderOutputData :: InteractiveRenderer -> OutputData -> IO ()
renderOutputData r = \case
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
  OdTokenInfo _                  -> pure ()  -- not rendered in interactive mode
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

------------------------------------------------------------------------
-- Formatting helpers
------------------------------------------------------------------------

th :: InteractiveRenderer -> IidyTheme
th = irTheme

-- | Format section heading with bold + color
formatSectionHeading :: InteractiveRenderer -> Text -> Text
formatSectionHeading r text =
  let clean = T.stripSuffix ":" text `orElse` text
  in colorizeBold (th r) (thSectionHeading (th r)) clean <> ":"
  where
    orElse Nothing  t = t
    orElse (Just v) _ = v

-- | Print section heading (without trailing newline)
printSectionHeading :: InteractiveRenderer -> Text -> IO ()
printSectionHeading r text = do
  hasContent <- readIORef (irHasRenderedContent r)
  if hasContent then TIO.putStrLn "" else pure ()
  TIO.putStr (formatSectionHeading r text)
  writeIORef (irHasRenderedContent r) True
  hFlush stdout

-- | Print section heading with newline
printSectionHeadingLn :: InteractiveRenderer -> Text -> IO ()
printSectionHeadingLn r text = do
  printSectionHeading r text
  TIO.putStrLn ""

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
  TIO.putStr (formatSectionEntry r label value)
  hFlush stdout

-- | Add content spacing (blank line before new content)
addContentSpacing :: InteractiveRenderer -> IO ()
addContentSpacing r = do
  hasContent <- readIORef (irHasRenderedContent r)
  if hasContent then TIO.putStrLn "" else pure ()
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
        envTag = firstJust (\k -> (k,) <$> Map.lookup k tags) envKeys
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
            in if remaining < length otherFormatted
               then take (remaining - 1) otherFormatted <> ["..."]
               else otherFormatted
    in T.intercalate ", " (envFormatted <> truncated)

-- | Pretty format parameters (sorted key=value)
prettyFormatParameters :: Map Text Text -> Text
prettyFormatParameters params
  | Map.null params = ""
  | otherwise = T.intercalate ", " $ map (\(k, v) -> k <> "=" <> v) $ sortBy (comparing fst) $ Map.toList params

-- | Pretty format a small map (sorted key=value)
prettyFormatSmallMap :: Map Text Text -> Text
prettyFormatSmallMap = prettyFormatParameters

-- | Find first matching value
firstJust :: (a -> Maybe b) -> [a] -> Maybe b
firstJust _ []     = Nothing
firstJust f (x:xs) = case f x of
  Just v  -> Just v
  Nothing -> firstJust f xs

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
  printSectionEntry r "CLI Arguments:" (styleMuted r (prettyFormatSmallMap (cmCliArguments meta)))
  printSectionEntry r "iidy Version:" (styleMuted r (cmVersion meta))
  let tokenText = styleMuted r (tiValue (cmPrimaryToken meta))
        <> " " <> styleMuted r ("(" <> formatTokenSource (tiSource (cmPrimaryToken meta)) <> ")")
  printSectionEntry r "Client Req Token:" tokenText
  let derived = cmDerivedTokens meta
  if not (null derived)
    then do
      printSectionEntry r "Derived Tokens:" (T.pack (show (length derived)) <> " tokens")
      mapM_ (\(i, tok) ->
        printSectionEntry r ("  [" <> T.pack (show i) <> "]")
          (styleMuted r (tiValue tok) <> " " <> styleMuted r ("(" <> formatTokenSource (tiSource tok) <> ")"))
        ) (zip [(1::Int)..] derived)
    else pure ()

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
  if showTimes
    then do
      case sdCreationTime def of
        Just t -> printSectionEntry r "Creation Time:" (styleMuted r (renderTimestamp t))
        Nothing -> pure ()
      case sdLastUpdatedTime def of
        Just t -> printSectionEntry r "Last Update Time:" (styleMuted r (renderTimestamp t))
        Nothing -> pure ()
    else pure ()
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
    then TIO.putStrLn (" " <> styleMuted r "No events found")
    else do
      let sorted = sortBy (comparing (seTimestamp . sewEvent)) (sedEvents evts)
          limited = case sedMaxEvents evts of
            Just mx -> take mx sorted
            Nothing -> sorted
          statusPad = calcPadding limited (seResourceStatus . sewEvent)
          rtypePad = calcPadding limited (seResourceType . sewEvent)
      mapM_ (renderSingleStackEvent r statusPad rtypePad) limited
      case sedTruncated evts of
        Just ti -> TIO.putStrLn ("  " <> styleMuted r
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
  TIO.putStrLn (" " <> ts <> " " <> status <> " " <> rtype <> " " <> logId <> dur)
  -- Show failure reason on new line
  case seResourceStatusReason event of
    Just reason | not (T.null reason) && T.isInfixOf "FAILED" (seResourceStatus event) ->
      let cleaned = case T.breakOnEnd "Initiated" reason of
            (_, after) | not (T.null after) -> T.strip after
            _ -> T.strip reason
          maxW = irTerminalWidth r - 2
          -- Simple word wrap
          wrapped = wrapText maxW cleaned
      in mapM_ (\line -> TIO.putStrLn ("  " <> colorize (th r) (thError (th r)) line)) wrapped
    _ -> pure ()

renderStackContents :: InteractiveRenderer -> StackContents -> IO ()
renderStackContents r contents = do
  -- Resources
  if not (null (scResources contents))
    then do
      printSectionHeadingLn r "Stack Resources"
      let idPad = calcPadding (scResources contents) sriLogicalResourceId
          rtypePad = calcPadding (scResources contents) sriResourceType
      mapM_ (\res ->
        TIO.putStrLn (
          formatLogicalId r (padRight (idPad + 1) (" " <> sriLogicalResourceId res))
          <> " " <> styleMuted r (padRight rtypePad (sriResourceType res))
          <> " " <> styleMuted r (fromMaybe "" (sriPhysicalResourceId res))
        )) (scResources contents)
    else pure ()
  -- Outputs
  if null (scOutputs contents)
    then do
      printSectionHeading r "Stack Outputs"
      TIO.putStrLn (" " <> styleMuted r "None")
    else do
      printSectionHeadingLn r "Stack Outputs"
      let keyPad = calcPadding (scOutputs contents) soiOutputKey
      mapM_ (\out ->
        TIO.putStrLn (
          formatLogicalId r (padRight (keyPad + 1) (" " <> soiOutputKey out))
          <> " " <> styleMuted r (soiOutputValue out)
        )) (scOutputs contents)
  -- Exports
  if not (null (scExports contents))
    then do
      let hasImports = any (not . null . seiImportingStacks) (scExports contents)
          isComplex = length (scExports contents) > 1 || hasImports
      if isComplex
        then printSectionHeadingLn r "Stack Exports"
        else printSectionHeading r "Stack Exports"
      let namePad = calcPadding (scExports contents) seiName
      mapM_ (\ex -> do
        TIO.putStrLn (
          formatLogicalId r (padRight (namePad + 1) (" " <> seiName ex))
          <> " " <> styleMuted r (seiValue ex))
        mapM_ (\imp -> TIO.putStrLn ("  " <> styleMuted r ("imported by " <> imp))) (seiImportingStacks ex)
        ) (scExports contents)
    else pure ()
  -- Current Status
  printSectionHeading r "Current Stack Status"
  TIO.putStrLn (" " <> colorizeResourceStatus (th r) (ssiStatus (scCurrentStatus contents))
    <> " " <> styleMuted r (fromMaybe "" (ssiStatusReason (scCurrentStatus contents))))
  -- Pending changesets
  if not (null (scPendingChangesets contents))
    then do
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
            TIO.putStrLn ("  Description: " <> styleMuted r desc)
            TIO.putStrLn ""
          _ -> pure ()
        mapM_ (renderChangesetChange r) (csiChanges cs)
        TIO.putStrLn ""
        ) (scPendingChangesets contents)
    else pure ()

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
  TIO.putStrLn (tsText <> msg)

renderCommandResult :: InteractiveRenderer -> CommandResult -> IO ()
renderCommandResult r res = do
  addContentSpacing r
  let statusText = if crSuccess res
                   then formatSectionHeading r "SUCCESS"
                   else colorize (th r) (thError (th r)) "FAILURE" <> ":"
  TIO.putStrLn (statusText <> " (" <> T.pack (show (crElapsedSeconds res)) <> "s)")
  case crMessage res of
    Just msg -> TIO.putStrLn msg
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
    SummaryFailure -> TIO.putStrLn "Fix and try again."
    _ -> pure ()

renderStackList :: InteractiveRenderer -> StackListDisplay -> IO ()
renderStackList r lst = do
  if null (sldStacks lst)
    then TIO.putStrLn "No stacks found"
    else do
      let timePad = 24 :: Int
          statusPad = calcPadding (sldStacks lst) sleStackStatus
          header = padRight timePad "Creation/Update Time,"
                <> " " <> padRight statusPad "Status,"
                <> " " <> if sldShowTags lst then "Name, Tags" else "Name"
      TIO.putStrLn (styleMuted r header)
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
        TIO.putStrLn (formatTimestampText r tsText <> " " <> statusColored <> " "
                      <> styleMuted r lifecycleIcon <> stackName <> tagsDisplay)
        -- Show failure reason
        case sleStatusReason stack of
          Just reason | not (T.null reason)
                      , T.isInfixOf "FAILED" (sleStackStatus stack)
                        || sleStackStatus stack == "ROLLBACK_COMPLETE"
                        || sleStackStatus stack == "UPDATE_ROLLBACK_COMPLETE"
            -> TIO.putStrLn ("  " <> styleMuted r reason)
          _ -> pure ()
        ) (sldStacks lst)

renderChangesetResult :: InteractiveRenderer -> ChangeSetCreationResult -> IO ()
renderChangesetResult r cs = do
  TIO.putStrLn ""
  TIO.putStrLn ("AWS Console URL for full changeset review: " <> styleMuted r (csrConsoleUrl cs))
  TIO.putStrLn ""
  printSectionHeadingLn r "Pending Changesets"
  mapM_ (\changeset -> do
    let ctText = case csiCreationTime changeset of
          Just t  -> formatTimestampText r (renderTimestamp t)
          Nothing -> "Unknown time"
    printSectionEntry r ctText
      (colorize (th r) (thPrimary (th r)) (csiChangeSetName changeset) <> " " <> csiStatus changeset)
    mapM_ (renderChangesetChange r) (csiChanges changeset)
    ) (csrPendingChangesets cs)
  TIO.putStrLn ""
  mapM_ TIO.putStrLn (csrNextSteps cs)

renderChangesetChange :: InteractiveRenderer -> ChangeInfo -> IO ()
renderChangesetChange r change = do
  let actionW = 8 :: Int
      logIdW = 30 :: Int
  case ciAction change of
    "Add" -> do
      let actionPadded = padRight actionW (ciAction change)
      TIO.putStrLn ("  " <> colorize (th r) (thSuccess (th r)) actionPadded
        <> " " <> padRight logIdW (ciLogicalResourceId change)
        <> " " <> styleMuted r (ciResourceType change))
    "Remove" -> do
      let resInfo = ciResourceType change <> maybe "" (" " <>) (ciPhysicalResourceId change)
          actionPadded = padRight actionW (ciAction change)
      TIO.putStrLn ("  " <> colorize (th r) (thError (th r)) actionPadded
        <> " " <> padRight logIdW (ciLogicalResourceId change)
        <> " " <> styleMuted r resInfo)
    "Modify" -> do
      let (actionText, actionColor) = case ciReplacement change of
            Just "True"        -> ("Replace", thError (th r))
            Just "Conditional" -> ("Replace?", thError (th r))
            _                  -> ("Modify", thWarning (th r))
          resInfo = ciResourceType change <> maybe "" (" " <>) (ciPhysicalResourceId change)
      case ciReplacement change of
        Nothing -> do
          let scopeText = maybe "" (T.intercalate ", ") (ciScope change)
          TIO.putStrLn ("  " <> colorize (th r) actionColor (padRight actionW actionText)
            <> " " <> padRight logIdW (ciLogicalResourceId change)
            <> " " <> colorize (th r) (thWarning (th r)) scopeText
            <> " " <> styleMuted r resInfo)
        Just "False" -> do
          let scopeText = maybe "" (T.intercalate ", ") (ciScope change)
          TIO.putStrLn ("  " <> colorize (th r) actionColor (padRight actionW actionText)
            <> " " <> padRight logIdW (ciLogicalResourceId change)
            <> " " <> colorize (th r) (thWarning (th r)) scopeText
            <> " " <> styleMuted r resInfo)
        _ ->
          TIO.putStrLn ("  " <> colorize (th r) actionColor (padRight actionW actionText)
            <> " " <> padRight logIdW (ciLogicalResourceId change)
            <> " " <> styleMuted r resInfo)
      -- Details
      mapM_ (\detail ->
        TIO.putStrLn ("    " <> styleMuted r (cdTarget detail) <> ": "
          <> styleMuted r (fromMaybe "Unknown" (cdChangeSource detail)))
        ) (ciDetails change)
    _ -> do
      let actionPadded = padRight actionW (ciAction change)
      TIO.putStrLn ("  " <> actionPadded
        <> " " <> padRight logIdW (ciLogicalResourceId change)
        <> " " <> styleMuted r (ciResourceType change))

renderStackDrift :: InteractiveRenderer -> StackDrift -> IO ()
renderStackDrift r drift = do
  if null (sdrDriftedResources drift)
    then TIO.putStrLn "No drift detected. Stack resources are in sync with template."
    else do
      printSectionHeadingLn r "Drifted Resources"
      let idPad = maximum (0 : map (T.length . drLogicalResourceId) (sdrDriftedResources drift))
          typePad = maximum (0 : map (T.length . drResourceType) (sdrDriftedResources drift))
      mapM_ (\d -> do
        TIO.putStrLn (" " <> colorize (th r) (thResourceId (th r)) (padRight idPad (drLogicalResourceId d))
          <> " " <> styleMuted r (padRight typePad (drResourceType d))
          <> " " <> styleMuted r (drPhysicalResourceId d))
        TIO.putStrLn ("  " <> colorize (th r) (thError (th r)) (drDriftStatus d))
        mapM_ (\pd -> do
          TIO.putStrLn ("   - property_path: " <> pdPropertyPath pd)
          case pdExpectedValue pd of
            Just v -> TIO.putStrLn ("     expected_value: " <> v)
            Nothing -> pure ()
          case pdActualValue pd of
            Just v -> TIO.putStrLn ("     actual_value: " <> v)
            Nothing -> pure ()
          case pdDifferenceType pd of
            Just v -> TIO.putStrLn ("     difference_type: " <> v)
            Nothing -> pure ()
          ) (drPropertyDifferences d)
        ) (sdrDriftedResources drift)
  TIO.putStrLn ""

renderError :: InteractiveRenderer -> ErrorInfo -> IO ()
renderError r err = do
  stopSpinner r
  TIO.putStrLn ""
  case eiErrorDetails err of
    ErrorStackAbsent ctx -> renderStackAbsentError r ctx
    ErrorGeneric details -> do
      TIO.putStrLn (colorizeBold (th r) (thError (th r)) "ERROR"
        <> ": " <> colorizeBold (th r) (thError (th r)) (eiMessage err))
      case details of
        Just detailsText -> do
          TIO.putStrLn ""
          TIO.putStrLn detailsText
        Nothing -> pure ()
      mapM_ (\sug -> TIO.putStrLn ("  \8226 " <> styleMuted r sug)) (eiSuggestions err)

renderNewStackEvents :: InteractiveRenderer -> [StackEventWithTiming] -> IO ()
renderNewStackEvents r events = do
  if null events then pure ()
  else do
    stopSpinner r
    let statusPad = calcPadding events (seResourceStatus . sewEvent)
        rtypePad = calcPadding events (seResourceType . sewEvent)
    mapM_ (renderSingleStackEvent r statusPad rtypePad) events
    -- Restart spinner for continued polling
    startSpinner r "Loading live events..."

renderOperationComplete :: InteractiveRenderer -> OperationCompleteInfo -> IO ()
renderOperationComplete r info = do
  stopSpinner r
  let msg = " " <> T.pack (show (ociElapsedSeconds info)) <> " seconds elapsed total."
  TIO.putStrLn (styleMuted r msg)

renderInactivityTimeout :: InteractiveRenderer -> InactivityTimeoutInfo -> IO ()
renderInactivityTimeout r info = do
  stopSpinner r
  let msg = " Inactivity timeout of " <> T.pack (show (itiTimeoutSeconds info)) <> " seconds reached. Stopping watch."
  TIO.putStrLn (styleMuted r msg)

renderConfirmationPrompt :: InteractiveRenderer -> ConfirmationRequest -> IO ()
renderConfirmationPrompt r req = do
  stopSpinner r
  isTty <- hIsTerminalDevice stdout
  if not isTty || not (ioEnableAnsi (irOptions r))
    then do
      TIO.putStrLn ("CONFIRMATION REQUIRED: " <> cfrMessage req)
      TIO.putStrLn "Use --yes flag to proceed automatically in non-interactive mode"
    else do
      TIO.putStr ("? " <> colorizeBold (th r) (thError (th r)) (cfrMessage req) <> " (y/N) ")
      hFlush stdout
      -- Note: actual stdin reading is handled by the caller

renderStackChangeDetails :: InteractiveRenderer -> StackChangeDetails -> IO ()
renderStackChangeDetails r details = do
  case scdChangeType details of
    ChangeCreate ->
      TIO.putStrLn (" " <> colorize (th r) (thInfo (th r)) "Creating new stack")
    ChangeUpdateWithChanges _ ->
      TIO.putStrLn (" " <> colorize (th r) (thInfo (th r)) "Updating existing stack")
    ChangeUpdateNoChanges ->
      TIO.putStrLn (" " <> colorize (th r) (thSuccess (th r)) "No changes detected so no stack update needed.")

renderStackAbsentInfo :: InteractiveRenderer -> StackAbsentInfo -> IO ()
renderStackAbsentInfo r info = do
  let prefix = colorizeBold (th r) (thSuccess (th r)) "info"
      sn = colorizeBold (th r) (thInfo (th r)) (saiStackName info)
  TIO.putStrLn (prefix <> " The stack " <> sn <> " is absent")
  TIO.putStrLn ("      env = " <> colorize (th r) (thPrimary (th r)) (saiEnvironment info))
  TIO.putStrLn ("      region = " <> colorize (th r) (thPrimary (th r)) (saiRegion info))
  TIO.putStrLn ("      account = " <> colorize (th r) (thPrimary (th r)) (saiAccount info))
  TIO.putStrLn ("      auth_arn = " <> colorize (th r) (thPrimary (th r)) (saiAuthArn info) <> ".")

renderStackAbsentError :: InteractiveRenderer -> StackAbsentInfo -> IO ()
renderStackAbsentError r ctx = do
  let prefix = colorizeBold (th r) (thError (th r)) "ERROR"
      sn = colorizeBold (th r) (thInfo (th r)) (saiStackName ctx)
  TIO.putStrLn (prefix <> " The stack " <> sn <> " is absent")
  TIO.putStrLn ("      env = " <> colorize (th r) (thPrimary (th r)) (saiEnvironment ctx))
  TIO.putStrLn ("      region = " <> colorize (th r) (thPrimary (th r)) (saiRegion ctx))
  TIO.putStrLn ("      account = " <> colorize (th r) (thPrimary (th r)) (saiAccount ctx))
  TIO.putStrLn ("      auth_arn = " <> colorize (th r) (thPrimary (th r)) (saiAuthArn ctx) <> ".")

renderCostEstimate :: InteractiveRenderer -> CostEstimate -> IO ()
renderCostEstimate r est = do
  printSectionEntry r "Stack cost estimator:" (colorize (th r) (thPrimary (th r)) (ceiUrl (ceInfo est)))

renderStackTemplate :: InteractiveRenderer -> StackTemplate -> IO ()
renderStackTemplate _r tmpl = do
  mapM_ (TIO.hPutStrLn stderr) (stStderrLines tmpl)
  TIO.putStrLn (stTemplateBody tmpl)

renderApprovalRequestResult :: InteractiveRenderer -> ApprovalRequestResult -> IO ()
renderApprovalRequestResult r res = do
  if arrAlreadyApproved res
    then TIO.putStrLn (colorize (th r) (thSuccess (th r)) "\128077 Your template has already been approved")
    else do
      printSectionHeadingLn r "Template Approval Request"
      TIO.putStrLn ("Successfully uploaded template to: " <> styleMuted r (arrPendingLocation res))
      TIO.putStrLn ""
      TIO.putStrLn "Approve template with:"
      mapM_ (\step -> TIO.putStrLn ("  " <> colorize (th r) (thPrimary (th r)) step)) (arrNextSteps res)

renderTemplateValidation :: InteractiveRenderer -> TemplateValidation -> IO ()
renderTemplateValidation r val = do
  if not (tvEnabled val)
    then pure ()
    else do
      if not (null (tvErrors val))
        then do
          printSectionHeadingLn r "Template Validation Errors"
          mapM_ (\e -> TIO.putStrLn (colorize (th r) (thError (th r)) "\10007"
            <> " " <> colorize (th r) (thError (th r)) e)) (tvErrors val)
        else pure ()
      if not (null (tvWarnings val))
        then do
          printSectionHeadingLn r "Template Validation Warnings"
          mapM_ (\w -> TIO.putStrLn (colorize (th r) (thWarning (th r)) "\9888"
            <> " " <> colorize (th r) (thWarning (th r)) w)) (tvWarnings val)
        else pure ()
      if null (tvErrors val) && null (tvWarnings val)
        then TIO.putStrLn (colorize (th r) (thSuccess (th r)) "\10003 Template validation passed")
        else pure ()

renderApprovalStatus :: InteractiveRenderer -> ApprovalStatus -> IO ()
renderApprovalStatus r st = do
  if apsAlreadyApproved st
    then TIO.putStrLn (colorize (th r) (thSuccess (th r)) "\128077 The template has already been approved")
    else do
      printSectionHeadingLn r "Approval Status"
      TIO.putStrLn ("Pending template: " <> styleMuted r (apsPendingLocation st))
      case apsApprovedLocation st of
        Just loc -> TIO.putStrLn ("Current approved: " <> styleMuted r loc)
        Nothing  -> TIO.putStrLn "No previously approved template found"

renderTemplateDiff :: InteractiveRenderer -> TemplateDiff -> IO ()
renderTemplateDiff r diff = do
  if not (tdHasChanges diff)
    then TIO.putStrLn (colorize (th r) (thSuccess (th r)) "Templates are identical")
    else do
      printSectionHeadingLn r "Template Changes"
      TIO.putStr (tdDiffOutput diff)

renderApprovalResult :: InteractiveRenderer -> ApprovalResult -> IO ()
renderApprovalResult r res = do
  if arApproved res
    then do
      TIO.putStrLn ""
      TIO.putStrLn (colorize (th r) (thSuccess (th r)) "Template has been successfully approved!")
      case arApprovedLocation res of
        Just loc -> TIO.putStrLn ("Approved template: " <> styleMuted r loc)
        Nothing  -> pure ()
    else TIO.putStrLn (colorize (th r) (thWarning (th r)) "Approval cancelled")

------------------------------------------------------------------------
-- Utility helpers
------------------------------------------------------------------------

-- | Detect environment from stack name or tags
detectEnvironment :: Text -> Map Text Text -> Text
detectEnvironment stackName tags
  | T.isInfixOf "production" stackName || Map.lookup "environment" tags == Just "production" = "production"
  | T.isInfixOf "integration" stackName || Map.lookup "environment" tags == Just "integration" = "integration"
  | T.isInfixOf "development" stackName || Map.lookup "environment" tags == Just "development" = "development"
  | otherwise = ""

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
