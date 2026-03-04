-- | Core stack operations: fetching, event polling, content collection.
--
-- Provides building blocks used by individual CFN operations.
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.StackOperations
  ( -- * Stack info
    getStack
  , getStackId
  , stackExists
    -- * Events
  , fetchStackEvents
  , fetchRecentStackEvents
  , fetchStackEventsUpTo
    -- * Content collection
  , collectStackContents
  , collectStackContentsWithStack
    -- * Event polling
  , pollForCompletion
  , pollForCompletionWith
  , PollConfig(..)
  , defaultPollConfig
  , PollResult(..)
    -- * Helpers (exported for testing)
  , stackNameFromId
  , isStackNotFoundError
    -- * AWS type conversion (exported for testing)
  , convertResource
  , convertOutput
  , convertChangeSetSummary
    -- * URL utilities
  , percentEncode
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import Control.Exception (try, throwIO)
import Control.Monad (unless)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Conduit (runConduit, (.|))
import qualified Data.Conduit.List as CL
import Data.IORef
import Data.Function ((&))
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, getCurrentTime, diffUTCTime)

import qualified Amazonka
import qualified Amazonka.CloudFormation as CF
import qualified Amazonka.CloudFormation.Types as CF
-- Import operation modules with unique qualifiers for unambiguous record fields
import qualified Amazonka.CloudFormation.DescribeStacks as DStacks
import qualified Amazonka.CloudFormation.DescribeStackEvents as DEvents
import qualified Amazonka.CloudFormation.DescribeStackResources as DRes
import qualified Amazonka.CloudFormation.ListChangeSets as LCS

import Lens.Micro ((.~))
import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.Status (StackStatus(..), fromCfnResourceStatus, fromCfnStackStatus)
import Iidy.Output.Types

------------------------------------------------------------------------
-- Stack info
------------------------------------------------------------------------

-- | Get a stack by name. Returns Nothing if stack doesn't exist.
-- Catches AWS ValidationError (stack does not exist) and returns Nothing.
getStack :: CfnContext -> Text -> IO (Maybe CF.Stack)
getStack ctx stackName = do
  let req = DStacks.newDescribeStacks
              { DStacks.stackName = Just stackName }
  result <- try (runResourceT $ Amazonka.send (cfnEnv ctx) req)
  case result of
    Left e | isStackNotFoundError e -> pure Nothing
    Left e  -> throwIO e  -- re-throw non-existence errors
    Right resp -> pure $ case resp.stacks of
      Just (s:_) -> Just s
      _          -> Nothing

-- | Check if an Amazonka error indicates the stack does not exist.
isStackNotFoundError :: Amazonka.Error -> Bool
isStackNotFoundError (Amazonka.ServiceError se) =
  se.code == Amazonka.ErrorCode "ValidationError"
  && case se.message of
       Just msg -> "does not exist" `T.isInfixOf` Amazonka.fromErrorMessage msg
       Nothing  -> False
isStackNotFoundError _ = False

-- | Get stack ID from stack name.
getStackId :: CfnContext -> Text -> IO (Maybe Text)
getStackId ctx sName = do
  mStack <- getStack ctx sName
  pure $ mStack >>= (.stackId)

-- | Check if a stack exists (and is not in DELETE_COMPLETE state)
stackExists :: CfnContext -> Text -> IO Bool
stackExists ctx sName = do
  mStack <- getStack ctx sName
  pure $ case mStack of
    Nothing -> False
    Just s  -> s.stackStatus /= CF.StackStatus_DELETE_COMPLETE

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

-- | Fetch all stack events across all pages (most recent first per page).
-- Uses pagination to collect beyond the single-page limit (~1MB per page).
-- Prefer 'fetchRecentStackEvents' for polling and display (single page).
fetchStackEvents :: CfnContext -> Text -> IO [CF.StackEvent]
fetchStackEvents ctx sId = do
  let req = DEvents.newDescribeStackEvents
              { DEvents.stackName = Just sId }
  pages <- runResourceT $ runConduit $
    Amazonka.paginate (cfnEnv ctx) req
    .| CL.consume
  pure $ concatMap (fromMaybe [] . (.stackEvents)) pages

-- | Fetch a single page of stack events (most recent first, up to ~100).
-- Sufficient for polling (new events appear on first page) and most
-- event displays. Avoids paginating entire event history.
fetchRecentStackEvents :: CfnContext -> Text -> IO [CF.StackEvent]
fetchRecentStackEvents ctx sId = do
  let req = DEvents.newDescribeStackEvents
              { DEvents.stackName = Just sId }
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req
  pure $ fromMaybe [] resp.stackEvents

-- | Fetch stack events across multiple pages until at least @maxEvents * 2@
-- events are collected or all pages are exhausted.
--
-- Matches Rust semantics: fetches enough pages to satisfy the requested count.
-- Use this for 'describe-stack' event display. Use 'fetchRecentStackEvents'
-- for polling loops (new events always appear on the first page).
fetchStackEventsUpTo :: CfnContext -> Text -> Int -> IO [CF.StackEvent]
fetchStackEventsUpTo ctx sId maxEvents = go Nothing []
  where
    target :: Int
    target = maxEvents * 2
    go :: Maybe Text -> [CF.StackEvent] -> IO [CF.StackEvent]
    go mToken acc
      | length acc >= target = pure acc
      | otherwise = do
          let req = mkDescribeStackEvents sId mToken
          resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req
          let events = fromMaybe [] resp.stackEvents
              acc'   = acc <> events
          case resp.nextToken of
            Nothing -> pure acc'
            Just tk -> go (Just tk) acc'

-- | Build a DescribeStackEvents request. Uses the amazonka lens to avoid
-- the DuplicateRecordFields ambiguity on @nextToken@ (shared by request
-- and response types).
mkDescribeStackEvents :: Text -> Maybe Text -> DEvents.DescribeStackEvents
mkDescribeStackEvents sId mToken =
  DEvents.newDescribeStackEvents
    { DEvents.stackName = Just sId
    } & DEvents.describeStackEvents_nextToken .~ mToken

------------------------------------------------------------------------
-- Content collection
------------------------------------------------------------------------

-- | Collect full stack contents (resources, outputs, exports, status, changesets).
-- Fetches the stack via DescribeStacks. Prefer 'collectStackContentsWithStack'
-- when the caller already has the stack object.
collectStackContents :: CfnContext -> Text -> IO StackContents
collectStackContents ctx sName = do
  mStack <- getStack ctx sName
  collectStackContentsWithStack ctx sName mStack

-- | Like 'collectStackContents' but accepts an already-fetched stack,
-- avoiding a redundant DescribeStacks call. Runs DescribeStackResources
-- and ListChangeSets concurrently for lower latency.
collectStackContentsWithStack :: CfnContext -> Text -> Maybe CF.Stack -> IO StackContents
collectStackContentsWithStack ctx sName mStack = do
  -- Run DescribeStackResources and ListChangeSets concurrently
  (resourcesResp, csPages) <- concurrently
    (runResourceT $ Amazonka.send (cfnEnv ctx) resReq)
    (runResourceT $ runConduit $
       Amazonka.paginate (cfnEnv ctx) (LCS.newListChangeSets sName)
       .| CL.consume)

  let resources = maybe [] (map convertResource) resourcesResp.stackResources
      changesets = mapMaybe convertChangeSetSummary
                     (concatMap (fromMaybe [] . (.summaries)) csPages)

  let outputs = case mStack of
        Nothing -> []
        Just s  -> mapMaybe convertOutput (fromMaybe [] s.outputs)
      statusInfo = case mStack of
        Nothing -> StackStatusInfo CreateFailed Nothing Nothing
        Just s  -> StackStatusInfo
          { ssiStatus = fromCfnStackStatus s.stackStatus
          , ssiStatusReason = s.stackStatusReason
          , ssiTimestamp = Nothing
          }

  -- Derive exports from stack outputs (only those with an export name).
  -- Matches Rust: convert_outputs_to_exports() in aws_conversion.rs.
  let stackExports = case mStack of
        Nothing -> []
        Just s  ->
          let sArn = fromMaybe "" s.stackId
          in  [ StackExportInfo
                  { seiName             = eName
                  , seiValue            = soiOutputValue o
                  , seiExportingStackId = sArn
                  , seiImportingStacks  = []
                  }
              | o <- outputs
              , Just eName <- [soiExportName o]
              ]

  pure StackContents
    { scResources = resources
    , scOutputs = outputs
    , scExports = stackExports
    , scCurrentStatus = statusInfo
    , scPendingChangesets = changesets
    }
  where
    resReq = DRes.newDescribeStackResources
               { DRes.stackName = Just sName }

------------------------------------------------------------------------
-- Event polling
------------------------------------------------------------------------

data PollConfig = PollConfig
  { pcIntervalSeconds       :: !Int
  , pcTimeoutSeconds        :: !(Maybe Int)         -- ^ overall poll timeout
  , pcInactivityTimeoutSecs :: !(Maybe Int)         -- ^ inactivity timeout
  , pcStartTime             :: !(Maybe UTCTime)     -- ^ operation start time (for duration calc)
  , pcWaitForStatusChange   :: !Bool                -- ^ wait for new events before checking terminal (watch-stack)
  , pcOnNewEvents           :: [CF.StackEvent] -> IO ()
  , pcOnOperationComplete   :: OperationCompleteInfo -> IO ()
  , pcOnInactivityTimeout   :: InactivityTimeoutInfo -> IO ()
  , pcOnPollTick            :: IO ()                -- ^ called each poll cycle (for spinner)
  }

defaultPollConfig :: PollConfig
defaultPollConfig = PollConfig
  { pcIntervalSeconds       = 2
  , pcTimeoutSeconds        = Nothing
  , pcInactivityTimeoutSecs = Nothing
  , pcStartTime             = Nothing
  , pcWaitForStatusChange   = False
  , pcOnNewEvents           = const (pure ())
  , pcOnOperationComplete   = const (pure ())
  , pcOnInactivityTimeout   = const (pure ())
  , pcOnPollTick            = pure ()
  }

-- | Result of a polling operation.
data PollResult
  = PollSuccess StackStatus  -- ^ Terminal status reached
  | PollTimeout              -- ^ Overall timeout elapsed
  | PollInactivityTimeout    -- ^ Inactivity timeout elapsed
  deriving stock (Show, Eq)

-- | Poll for stack operation completion.
-- Returns a PollResult describing how polling ended.
pollForCompletion
  :: CfnContext
  -> Text              -- ^ stack ID (use ID not name for deletes)
  -> [StackStatus]     -- ^ terminal statuses
  -> PollConfig
  -> IO PollResult
pollForCompletion ctx sId = pollForCompletionWith (fetchRecentStackEvents ctx sId) sId

-- | Testable polling loop — takes an event-fetching action instead of CfnContext.
pollForCompletionWith
  :: IO [CF.StackEvent]  -- ^ event fetcher
  -> Text                -- ^ stack ID (for isStackEvent check)
  -> [StackStatus]       -- ^ terminal statuses
  -> PollConfig
  -> IO PollResult
pollForCompletionWith fetchEvents sId terminalStatuses config = do
  startTime <- maybe getCurrentTime pure (pcStartTime config)
  lastEventTimeRef <- newIORef startTime
  hasSeenNewEventsRef <- newIORef False
  let go :: Set.Set Text -> IO PollResult
      go lastEventSet = do
        threadDelay (pcIntervalSeconds config * 1000000)
        pcOnPollTick config
        events <- fetchEvents
        now <- getCurrentTime
        -- Filter to new events only (O(log n) per event via Set.notMember)
        let newEvents = filter (\e -> Set.notMember e.eventId lastEventSet) events
        unless (null newEvents) $ do
          writeIORef lastEventTimeRef now
          writeIORef hasSeenNewEventsRef True
          -- reverse: events arrive most-recent-first; emit oldest-first
          pcOnNewEvents config (reverse newEvents)
        -- Check inactivity timeout (only when we've seen events or not waiting)
        hasSeenNewEvents <- readIORef hasSeenNewEventsRef
        lastEventTime <- readIORef lastEventTimeRef
        let inactivityElapsed = round (diffUTCTime now lastEventTime) :: Int
        case pcInactivityTimeoutSecs config of
          Just timeout | timeout > 0 && null newEvents && inactivityElapsed > timeout
                       , not (pcWaitForStatusChange config) || hasSeenNewEvents -> do
            let elapsed = round (diffUTCTime now startTime) :: Int
            pcOnInactivityTimeout config InactivityTimeoutInfo
              { itiTimeoutSeconds     = timeout
              , itiElapsedSeconds     = elapsed
              , itiOperationStartTime = startTime
              }
            pure PollInactivityTimeout
          _ -> do
            -- Check overall timeout
            let totalElapsed = round (diffUTCTime now startTime) :: Int
            case pcTimeoutSeconds config of
              Just t | t > 0 && totalElapsed > t -> pure PollTimeout
              _ -> do
                -- Check if we hit a terminal status
                let stackEvents = filter isStackEvent events
                    mCurrentStatus = case stackEvents of
                      (e:_) -> fmap fromCfnResourceStatus e.resourceStatus
                      _     -> Nothing
                -- When pcWaitForStatusChange is True, only exit on terminal
                -- status after we've seen new events (i.e., a new operation started)
                let shouldCheckTerminal = not (pcWaitForStatusChange config)
                                       || hasSeenNewEvents
                case mCurrentStatus of
                  Just currentStatus | shouldCheckTerminal && currentStatus `elem` terminalStatuses -> do
                    let elapsed = round (diffUTCTime now startTime) :: Int
                    pcOnOperationComplete config OperationCompleteInfo
                      { ociElapsedSeconds        = elapsed
                      , ociOperationStartTime    = startTime
                      , ociSkipRemainingSections = currentStatus == DeleteComplete
                      }
                    pure (PollSuccess currentStatus)
                  _ ->
                    let !newSet = Set.union lastEventSet
                                   (Set.fromList (map (.eventId) newEvents))
                    in go newSet
  -- Note: starts with empty seen set, so the first poll batch includes all
  -- pre-existing events. This matches the Rust behavior. watchStack has its
  -- own second dedup layer to filter these; write operations emit them as
  -- part of the initial event display.
  go Set.empty
  where
    -- | True only for the stack's own status event (logicalResourceId = stackName
    -- AND resourceType = AWS::CloudFormation::Stack). Using AND prevents nested
    -- stack events from being mistaken for the top-level stack's status event.
    isStackEvent :: CF.StackEvent -> Bool
    isStackEvent e =
      e.logicalResourceId == Just (stackNameFromId sId)
      && e.resourceType == Just "AWS::CloudFormation::Stack"

-- | Extract stack name from a stack ID (ARN format: arn:.../stackName/guid)
stackNameFromId :: Text -> Text
stackNameFromId sid = case T.splitOn "/" sid of
  (_:name:_) -> name
  _          -> sid

------------------------------------------------------------------------
-- AWS type conversion helpers
------------------------------------------------------------------------

convertResource :: CF.StackResource -> StackResourceInfo
convertResource r = StackResourceInfo
  { sriLogicalResourceId = r.logicalResourceId
  , sriPhysicalResourceId = r.physicalResourceId
  , sriResourceType = r.resourceType
  , sriResourceStatus = fromCfnResourceStatus r.resourceStatus
  , sriResourceStatusReason = r.resourceStatusReason
  , sriLastUpdated = Just r.timestamp.fromTime
  }

convertOutput :: CF.Output -> Maybe StackOutputInfo
convertOutput o = do
  key <- o.outputKey
  pure StackOutputInfo
    { soiOutputKey = key
    , soiOutputValue = fromMaybe "" o.outputValue
    , soiDescription = o.description
    , soiExportName = o.exportName
    }

convertChangeSetSummary :: CF.ChangeSetSummary -> Maybe ChangeSetInfo
convertChangeSetSummary cs = do
  name <- cs.changeSetName
  csId <- cs.changeSetId
  pure ChangeSetInfo
    { csiChangeSetName = name
    , csiChangeSetId = csId
    , csiStackId = fromMaybe "" cs.stackId
    , csiStackName = fromMaybe "" cs.stackName
    , csiDescription = cs.description
    , csiStatus = maybe "" CF.fromChangeSetStatus cs.status
    , csiStatusReason = cs.statusReason
    , csiCreationTime = fmap (.fromTime) cs.creationTime
    , csiExecutionStatus = CF.fromExecutionStatus <$> cs.executionStatus
    , csiChanges = []
    }

------------------------------------------------------------------------
-- URL utilities
------------------------------------------------------------------------

-- | Percent-encode a text string for use in URL query parameter values.
-- Encodes everything except unreserved characters (RFC 3986).
-- Correctly handles Unicode by UTF-8 encoding first.
-- Lives here (not a Util module) to avoid circular deps: both Changeset
-- and DescribeStack need it, and both already import StackOperations.
percentEncode :: Text -> Text
percentEncode t = T.concat $ map encByte (BS.unpack (TE.encodeUtf8 t))
  where
    encByte b
      | isUnreserved b = T.singleton (toEnum (fromIntegral b))
      | otherwise      = T.pack ['%', hexDigit (b `div` 16), hexDigit (b `mod` 16)]
    isUnreserved b = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                  || (b >= 0x30 && b <= 0x39) || b `elem` [0x2D, 0x2E, 0x5F, 0x7E]
    hexDigit n
      | n < 10    = toEnum (fromEnum '0' + fromIntegral n)
      | otherwise = toEnum (fromEnum 'A' + fromIntegral n - 10)
