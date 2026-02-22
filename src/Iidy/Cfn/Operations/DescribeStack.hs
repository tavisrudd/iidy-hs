-- | Describe-stack CloudFormation operation.
--
-- Fetches the stack definition, recent events, and current contents
-- and returns them as a list of OutputData for rendering.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.DescribeStack
  ( describeStack
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as Map

import Data.Coerce (coerce)
import Data.Time (UTCTime)
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
buildEventsDisplay sName numEvents events =
  let total      = length events
      taken      = take numEvents events
      converted  = map convertEvent taken
      wrapped    = map (\e -> StackEventWithTiming { sewEvent = e, sewDurationSeconds = Nothing }) converted
      truncInfo  = if total > numEvents
                     then Just TruncationInfo { truncShown = numEvents, truncTotal = total }
                     else Nothing
  in StackEventsDisplay
       { sedTitle     = "Stack Events: " <> sName
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
    <> T.replace "/" "%2F" stackArn
