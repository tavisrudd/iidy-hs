-- | DescribeStackDrift CloudFormation operation.
--
-- Full drift detection flow: fetch stack definition, check cache,
-- initiate detection if needed, poll to completion, collect and
-- render drift results.
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.DescribeStackDrift
  ( describeStackDrift
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime, diffUTCTime)
import Data.Coerce (coerce)
import Control.Concurrent (threadDelay)
import Data.Function ((&))
import Control.Lens ((.~))

import Control.Monad.Trans.Resource (runResourceT)

import qualified Amazonka
import qualified Amazonka.CloudFormation.DetectStackDrift as DSD
import qualified Amazonka.CloudFormation.DescribeStackDriftDetectionStatus as DSDDS
import qualified Amazonka.CloudFormation.DescribeStackResourceDrifts as DSRD
import qualified Amazonka.CloudFormation.Types as CF

import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.StackOperations (getStack)
import Iidy.Cfn.Operations.DescribeStack (convertStack)
import Iidy.Output.Types

------------------------------------------------------------------------
-- Main entry point
------------------------------------------------------------------------

-- | Full describe-stack-drift operation.
--
-- Steps:
--   1. Fetch stack definition and emit it.
--   2. Check drift cache — skip detection if recent enough.
--   3. Initiate drift detection if needed.
--   4. Poll DescribeStackDriftDetectionStatus until complete.
--   5. Collect drift results via DescribeStackResourceDrifts.
--   6. Convert and emit StackDrift.
describeStackDrift
  :: CfnContext
  -> Text            -- ^ Stack name
  -> Int             -- ^ Drift cache seconds (default 300)
  -> (OutputData -> IO ())  -- ^ emit callback
  -> IO (Either Text ())
describeStackDrift ctx stackName driftCacheSecs emit = do
  -- Step 1: Fetch and emit StackDefinition
  mStack <- getStack ctx stackName
  case mStack of
    Nothing ->
      pure $ Left ("Stack not found: " <> stackName)
    Just cfnStack -> do
      let regionText = Amazonka.fromRegion (Amazonka.region (cfnEnv ctx))
          stackDef   = convertStack cfnStack regionText
      emit (OdStackDefinition stackDef True)

      -- Step 2: Check drift cache
      needsCheck <- needsDriftCheck cfnStack driftCacheSecs
      if needsCheck
        then do
          -- Step 3: Emit status update and initiate detection
          now <- getCurrentTime
          emit (OdStatusUpdate StatusUpdate
            { suMessage   = "Checking for stack drift..."
            , suTimestamp = now
            , suLevel     = LevelInfo
            })
          let req = DSD.newDetectStackDrift stackName
          resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req
          let detectionId = resp.stackDriftDetectionId

          -- Step 4: Poll for completion
          completed <- pollDriftDetection ctx driftPollMaxIterations detectionId
          if not completed
            then do
              let timeoutMins = (driftPollMaxIterations * driftPollIntervalSecs) `div` 60
              now2 <- getCurrentTime
              emit (OdStatusUpdate StatusUpdate
                { suMessage   = "Drift detection timed out after "
                                <> T.pack (show timeoutMins)
                                <> " minutes. Results may be incomplete."
                , suTimestamp = now2
                , suLevel     = LevelWarning
                })
            else pure ()
        else
          pure ()

      -- Step 5-6: Collect and emit drift results
      driftData <- collectDriftData ctx stackName
      emit (OdStackDrift driftData)
      pure $ Right ()

------------------------------------------------------------------------
-- Drift cache check
------------------------------------------------------------------------

-- | Determine if a new drift detection is needed based on cache.
needsDriftCheck :: CF.Stack -> Int -> IO Bool
needsDriftCheck cfnStack cacheSecs = do
  now <- getCurrentTime
  let mDriftInfo = cfnStack.driftInformation
  pure $ case mDriftInfo of
    Nothing -> True
    Just di ->
      di.stackDriftStatus == CF.StackDriftStatus_NOT_CHECKED
        || checkTimestampStale di now cacheSecs

-- | Check if the last drift check timestamp is stale.
checkTimestampStale :: CF.StackDriftInformation -> UTCTime -> Int -> Bool
checkTimestampStale di now cacheSecs =
  case di.lastCheckTimestamp of
    Nothing -> True
    Just ts ->
      let checkTime = coerce ts :: UTCTime
          elapsed   = diffUTCTime now checkTime
      in elapsed > fromIntegral cacheSecs

------------------------------------------------------------------------
-- Drift detection polling
------------------------------------------------------------------------

-- | Drift polling interval in seconds.
driftPollIntervalSecs :: Int
driftPollIntervalSecs = 3

-- | Max drift polling iterations. At 3s per iteration, 100 iterations = 5 minutes.
-- Note: Rust iidy polls indefinitely. We add a safety cap to avoid infinite hangs
-- on stuck drift detections while still allowing plenty of time for large stacks.
driftPollMaxIterations :: Int
driftPollMaxIterations = 100

-- | Poll DescribeStackDriftDetectionStatus until detection completes.
-- Returns True if detection completed, False if timed out.
pollDriftDetection :: CfnContext -> Int -> Text -> IO Bool
pollDriftDetection ctx maxIter detectionId = go (0 :: Int)
  where
    go :: Int -> IO Bool
    go iteration
      | iteration >= maxIter = pure False
      | otherwise = do
          let req = DSDDS.newDescribeStackDriftDetectionStatus detectionId
          resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req
          case resp.detectionStatus of
            s | s == CF.StackDriftDetectionStatus_DETECTION_IN_PROGRESS -> do
              threadDelay (driftPollIntervalSecs * 1_000_000)
              go (iteration + 1)
            _ -> pure True

------------------------------------------------------------------------
-- Drift data collection
------------------------------------------------------------------------

-- | Collect all drifted resources (paginated), filtering out InSync.
collectDriftData :: CfnContext -> Text -> IO StackDrift
collectDriftData ctx stackName = do
  allDrifts <- fetchAllDriftPages ctx stackName Nothing
  let drifted = filter (not . isInSync) allDrifts
  pure StackDrift { sdrDriftedResources = map convertDrift drifted }

-- | Paginate through DescribeStackResourceDrifts.
fetchAllDriftPages
  :: CfnContext -> Text -> Maybe Text -> IO [CF.StackResourceDrift]
fetchAllDriftPages ctx stackName mToken = do
  let req = mkDriftReq stackName mToken
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req
  let drifts    = resp.stackResourceDrifts
      moreToken = driftRespNextToken resp
  case moreToken of
    Nothing    -> pure drifts
    Just token -> do
      rest <- fetchAllDriftPages ctx stackName (Just token)
      pure (drifts ++ rest)

-- | Build a DescribeStackResourceDrifts request with optional pagination token.
mkDriftReq :: Text -> Maybe Text -> DSRD.DescribeStackResourceDrifts
mkDriftReq sName mt =
  DSRD.newDescribeStackResourceDrifts sName
    & DSRD.describeStackResourceDrifts_nextToken .~ mt

-- | Extract nextToken from response (typed to disambiguate).
driftRespNextToken :: DSRD.DescribeStackResourceDriftsResponse -> Maybe Text
driftRespNextToken r = r.nextToken

-- | Check if a resource drift status is InSync.
isInSync :: CF.StackResourceDrift -> Bool
isInSync d =
  d.stackResourceDriftStatus == CF.StackResourceDriftStatus_IN_SYNC

-- | Convert an AWS StackResourceDrift to our output DriftedResource.
convertDrift :: CF.StackResourceDrift -> DriftedResource
convertDrift d = DriftedResource
  { drLogicalResourceId   = d.logicalResourceId
  , drPhysicalResourceId  = fromMaybe "unknown" d.physicalResourceId
  , drResourceType        = d.resourceType
  , drDriftStatus         = CF.fromStackResourceDriftStatus d.stackResourceDriftStatus
  , drPropertyDifferences = map convertPropDiff
                              (fromMaybe [] d.propertyDifferences)
  }

-- | Convert an AWS PropertyDifference to our output type.
convertPropDiff :: CF.PropertyDifference -> PropertyDifference
convertPropDiff pd = PropertyDifference
  { pdPropertyPath   = pd.propertyPath
  , pdExpectedValue  = Just pd.expectedValue
  , pdActualValue    = Just pd.actualValue
  , pdDifferenceType = Just (CF.fromDifferenceType pd.differenceType)
  }
