-- | Core stack operations: fetching, event polling, content collection.
--
-- Provides building blocks used by individual CFN operations.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.StackOperations
  ( -- * Stack info
    getStack
  , getStackId
  , stackExists
    -- * Events
  , fetchStackEvents
    -- * Content collection
  , collectStackContents
    -- * Event polling
  , pollForCompletion
  , pollForCompletionWith
  , PollConfig(..)
  , defaultPollConfig
  , PollResult(..)
    -- * Helpers (exported for testing)
  , stackNameFromId
    -- * URL utilities
  , percentEncode
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (try, throwIO)
import Control.Monad (when)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Conduit (runConduit, (.|))
import qualified Data.Conduit.List as CL
import Data.IORef
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
import qualified Amazonka.CloudFormation.ListExports as LE

import Iidy.Cfn.Context (CfnContext(..))
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
fetchStackEvents :: CfnContext -> Text -> IO [CF.StackEvent]
fetchStackEvents ctx sId = do
  let req = DEvents.newDescribeStackEvents
              { DEvents.stackName = Just sId }
  pages <- runResourceT $ runConduit $
    Amazonka.paginate (cfnEnv ctx) req
    .| CL.consume
  pure $ concatMap (fromMaybe [] . (.stackEvents)) pages

------------------------------------------------------------------------
-- Content collection
------------------------------------------------------------------------

-- | Collect full stack contents (resources, outputs, exports, status, changesets)
collectStackContents :: CfnContext -> Text -> IO StackContents
collectStackContents ctx sName = do
  -- Fetch resources
  let resReq = DRes.newDescribeStackResources
                 { DRes.stackName = Just sName }
  resourcesResp <- runResourceT $ Amazonka.send (cfnEnv ctx) resReq
  let resources = map convertResource (fromMaybe [] resourcesResp.stackResources)

  -- Fetch stack for outputs and status
  mStack <- getStack ctx sName
  let outputs = case mStack of
        Nothing -> []
        Just s  -> mapMaybe convertOutput (fromMaybe [] s.outputs)
      statusInfo = case mStack of
        Nothing -> StackStatusInfo "UNKNOWN" Nothing Nothing
        Just s  -> StackStatusInfo
          { ssiStatus = CF.fromStackStatus s.stackStatus
          , ssiStatusReason = s.stackStatusReason
          , ssiTimestamp = Nothing
          }

  -- Fetch pending changesets (paginated — ListChangeSets is capped per page)
  csPages <- runResourceT $ runConduit $
    Amazonka.paginate (cfnEnv ctx) (LCS.newListChangeSets sName)
    .| CL.consume
  let changesets = mapMaybe convertChangeSetSummary
                     (concatMap (fromMaybe [] . (.summaries)) csPages)

  -- Fetch exports from this stack (paginated — ListExports capped at 100/page).
  -- NOTE: ListExports has no server-side stack filter, so we must fetch ALL
  -- account exports and filter client-side by stack ARN. This matches the
  -- Rust implementation. May be slow for accounts with many exports.
  exportPages <- runResourceT $ runConduit $
    Amazonka.paginate (cfnEnv ctx) LE.newListExports
    .| CL.consume
  let allExports = concatMap (fromMaybe [] . (.exports)) exportPages
      stackExports = case mStack of
        Nothing -> []
        Just s  ->
          [ StackExportInfo
              { seiName             = fromMaybe "" e.name
              , seiValue            = fromMaybe "" e.value
              , seiExportingStackId = fromMaybe "" e.exportingStackId
              , seiImportingStacks  = []
              }
          | e <- allExports
          , Just sArn <- [s.stackId]
          , e.exportingStackId == Just sArn
          ]

  pure StackContents
    { scResources = resources
    , scOutputs = outputs
    , scExports = stackExports
    , scCurrentStatus = statusInfo
    , scPendingChangesets = changesets
    }

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
  = PollSuccess Text        -- ^ Terminal status reached
  | PollTimeout             -- ^ Overall timeout elapsed
  | PollInactivityTimeout   -- ^ Inactivity timeout elapsed
  deriving stock (Show, Eq)

-- | Poll for stack operation completion.
-- Returns a PollResult describing how polling ended.
pollForCompletion
  :: CfnContext
  -> Text          -- ^ stack ID (use ID not name for deletes)
  -> [Text]        -- ^ terminal status strings
  -> PollConfig
  -> IO PollResult
pollForCompletion ctx sId = pollForCompletionWith (fetchStackEvents ctx sId) sId

-- | Testable polling loop — takes an event-fetching action instead of CfnContext.
pollForCompletionWith
  :: IO [CF.StackEvent]  -- ^ event fetcher
  -> Text                -- ^ stack ID (for isStackEvent check)
  -> [Text]              -- ^ terminal status strings
  -> PollConfig
  -> IO PollResult
pollForCompletionWith fetchEvents sId terminalStatuses config = do
  startTime <- maybe getCurrentTime pure (pcStartTime config)
  lastEventTimeRef <- newIORef startTime
  hasSeenNewEventsRef <- newIORef False
  go startTime lastEventTimeRef hasSeenNewEventsRef Set.empty
  where
    go :: UTCTime -> IORef UTCTime -> IORef Bool -> Set.Set Text -> IO PollResult
    go startTime lastEventTimeRef hasSeenNewEventsRef lastEventSet = do
      threadDelay (pcIntervalSeconds config * 1000000)
      pcOnPollTick config
      events <- fetchEvents
      now <- getCurrentTime
      -- Filter to new events only (O(log n) per event via Set.notMember)
      let newEvents = filter (\e -> Set.notMember e.eventId lastEventSet) events
      when (not (null newEvents)) $ do
        writeIORef lastEventTimeRef now
        writeIORef hasSeenNewEventsRef True
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
                  currentStatus = case stackEvents of
                    (e:_) -> maybe "" CF.fromResourceStatus e.resourceStatus
                    _     -> ""
              -- When pcWaitForStatusChange is True, only exit on terminal
              -- status after we've seen new events (i.e., a new operation started)
              let shouldCheckTerminal = not (pcWaitForStatusChange config)
                                     || hasSeenNewEvents
              if shouldCheckTerminal && currentStatus `elem` terminalStatuses
                then do
                  let elapsed = round (diffUTCTime now startTime) :: Int
                      isDelete = "DELETE_COMPLETE" `elem` terminalStatuses
                  pcOnOperationComplete config OperationCompleteInfo
                    { ociElapsedSeconds        = elapsed
                    , ociOperationStartTime    = startTime
                    , ociSkipRemainingSections = isDelete && currentStatus == "DELETE_COMPLETE"
                    }
                  pure (PollSuccess currentStatus)
                else
                  let newEventIds = Set.fromList (map (.eventId) newEvents)
                  in go startTime lastEventTimeRef hasSeenNewEventsRef
                        (Set.union lastEventSet newEventIds)

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
  , sriResourceStatus = CF.fromResourceStatus r.resourceStatus
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
