-- | Describe-stack CloudFormation operation.
--
-- Fetches the stack definition, recent events, and current contents
-- and returns them as a list of OutputData for rendering.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.DescribeStack
  ( describeStack
  , convertEvent
  , convertEventWithDuration
  , calculateEventDurations
  , convertStack
  , buildEventsDisplay
  , buildConsoleUrl
  ) where

import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T

import Data.Coerce (coerce)
import Data.Time (UTCTime, diffUTCTime)
import qualified Amazonka
import qualified Amazonka.CloudFormation as CF
import qualified Amazonka.CloudFormation.Types as CF

import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.StackOperations
  ( getStack
  , fetchStackEvents
  , collectStackContents
  )
import Iidy.Output.Types

------------------------------------------------------------------------
-- Main entry point
------------------------------------------------------------------------

-- | Describe a CloudFormation stack.
--
-- Fetches the stack definition, takes the first @numEvents@ events,
-- and collects current stack contents (resources, outputs, changesets).
-- Returns a list of OutputData suitable for rendering.
describeStack :: CfnContext -> Text -> Int -> IO (Either Text [OutputData])
describeStack ctx stackName numEvents = do
  mStack <- getStack ctx stackName
  case mStack of
    Nothing ->
      pure $ Left ("Stack not found: " <> stackName)
    Just cfnStack -> do
      events    <- fetchStackEvents ctx stackName
      contents  <- collectStackContents ctx stackName
      let regionText    = Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))
          stackDef      = convertStack cfnStack regionText
          eventsDisplay = buildEventsDisplay stackName numEvents events
      pure $ Right
        [ OdStackDefinition stackDef True
        , OdStackEvents eventsDisplay
        , OdStackContents contents
        ]

------------------------------------------------------------------------
-- Stack definition conversion
------------------------------------------------------------------------

-- | Convert a raw CF.Stack into a StackDefinition for rendering.
convertStack :: CF.Stack -> Text -> StackDefinition
convertStack s regionText =
  let stackArn     = fromMaybe "" s.stackId
      consoleUrl   = buildConsoleUrl regionText stackArn
      capTexts     = map (.fromCapability) (fromMaybe [] s.capabilities)
      tagMap       = Map.fromList
                       [ (t.key, t.value)
                       | t <- fromMaybe [] s.tags
                       ]
      paramMap     = Map.fromList
                       [ ( fromMaybe "" p.parameterKey
                         , fromMaybe "" p.parameterValue
                         )
                       | p <- fromMaybe [] s.parameters
                       ]
      notifArns    = fromMaybe [] s.notificationARNs
  in StackDefinition
       { sdName                  = s.stackName
       , sdStacksetName          = Map.lookup "StackSetName" tagMap
       , sdDescription           = s.description
       , sdStatus                = CF.fromStackStatus s.stackStatus
       , sdStatusReason          = s.stackStatusReason
       , sdCapabilities          = capTexts
       , sdServiceRole           = s.roleARN
       , sdTags                  = tagMap
       , sdParameters            = paramMap
       , sdDisableRollback       = fromMaybe False s.disableRollback
       , sdTerminationProtection = fromMaybe False s.enableTerminationProtection
       , sdCreationTime          = Just (coerce s.creationTime :: UTCTime)
       , sdLastUpdatedTime       = fmap (\t -> coerce t :: UTCTime) s.lastUpdatedTime
       , sdTimeoutInMinutes      = fmap fromIntegral s.timeoutInMinutes
       , sdNotificationArns      = notifArns
       , sdStackPolicy           = Nothing
       , sdArn                   = stackArn
       , sdConsoleUrl            = consoleUrl
       , sdRegion                = regionText
       }

------------------------------------------------------------------------
-- Events display construction
------------------------------------------------------------------------

-- | Build a StackEventsDisplay from raw CF events, limited to @n@ entries.
buildEventsDisplay :: Text -> Int -> [CF.StackEvent] -> StackEventsDisplay
buildEventsDisplay _sName numEvents events =
  let total      = length events
      taken      = take numEvents events
      converted  = map convertEvent taken
      wrapped    = calculateEventDurations converted
      truncInfo  = if total > numEvents
                     then Just TruncationInfo { truncShown = numEvents, truncTotal = total }
                     else Nothing
  in StackEventsDisplay
       { sedTitle     = "Previous Stack Events (max " <> T.pack (show numEvents) <> "):"
       , sedEvents    = wrapped
       , sedMaxEvents = Just numEvents
       , sedTruncated = truncInfo
       }

-- | Convert a raw CF.StackEvent to an output StackEvent.
convertEvent :: CF.StackEvent -> StackEvent
convertEvent e = StackEvent
  { seEventId              = e.eventId
  , seStackId              = e.stackId
  , seStackName            = e.stackName
  , seLogicalResourceId    = fromMaybe "" e.logicalResourceId
  , sePhysicalResourceId   = e.physicalResourceId
  , seResourceType         = fromMaybe "" e.resourceType
  , seTimestamp            = Just (coerce e.timestamp :: UTCTime)
  , seResourceStatus       = maybe "" CF.fromResourceStatus e.resourceStatus
  , seResourceStatusReason = e.resourceStatusReason
  , seResourceProperties   = e.resourceProperties
  , seClientRequestToken   = e.clientRequestToken
  }

-- | Calculate per-resource durations by matching IN_PROGRESS → COMPLETE/FAILED pairs.
-- Used for past/historical events (describe-stack). Sorts events chronologically
-- to properly track start/end pairs, then returns them in the original order.
calculateEventDurations :: [StackEvent] -> [StackEventWithTiming]
calculateEventDurations events =
  let -- Sort chronologically (oldest first) for duration tracking
      sorted = sortBy (comparing seTimestamp) events
      -- Track start times per resource key (logicalId/resourceType)
      durations = go Map.empty [] sorted
      -- Build lookup by event ID
      durMap = Map.fromList durations
  in map (\e -> StackEventWithTiming e (Map.lookup (seEventId e) durMap >>= id)) events
  where
    go :: Map.Map Text UTCTime -> [(Text, Maybe Int)] -> [StackEvent] -> [(Text, Maybe Int)]
    go _ acc [] = acc
    go starts acc (e:es) =
      let key = seLogicalResourceId e <> "/" <> seResourceType e
          status = seResourceStatus e
          (starts', dur) = case seTimestamp e of
            Nothing -> (starts, Nothing)
            Just ts
              | "_IN_PROGRESS" `T.isSuffixOf` status ->
                  (Map.insert key ts starts, Nothing)
              | "_COMPLETE" `T.isSuffixOf` status || "_FAILED" `T.isSuffixOf` status ->
                  case Map.lookup key starts of
                    Just startTs ->
                      let secs = max 0 (floor (diffUTCTime ts startTs)) :: Int
                      in (starts, Just secs)
                    Nothing -> (starts, Nothing)
              | otherwise -> (starts, Nothing)
      in go starts' ((seEventId e, dur) : acc) es

-- | Convert a raw CF.StackEvent to a StackEventWithTiming using the operation start time.
-- Duration = event_time - operation_start_time (used for live events during polling).
convertEventWithDuration :: UTCTime -> CF.StackEvent -> StackEventWithTiming
convertEventWithDuration startTime e =
  let converted = convertEvent e
      dur = case seTimestamp converted of
        Just ts -> Just (max 0 (floor (diffUTCTime ts startTime) :: Int))
        Nothing -> Nothing
  in StackEventWithTiming converted dur

------------------------------------------------------------------------
-- Console URL helper
------------------------------------------------------------------------

-- | Build the AWS CloudFormation console URL for a stack.
buildConsoleUrl :: Text -> Text -> Text
buildConsoleUrl regionText stackArn =
  "https://"
    <> regionText
    <> ".console.aws.amazon.com/cloudformation/home?region="
    <> regionText
    <> "#/stacks/stackinfo?stackId="
    <> stackArn
