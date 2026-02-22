-- | DetectStackDrift CloudFormation operation.
--
-- Initiates drift detection for a stack and returns the detection ID.
-- Actual drift results require polling DescribeStackDriftDetectionStatus.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.DescribeStackDrift
  ( detectStackDrift
  ) where

import Data.Text (Text)

import Control.Monad.Trans.Resource (runResourceT)

import qualified Amazonka
import qualified Amazonka.CloudFormation.DetectStackDrift as DSD

import Iidy.Cfn.Context (CfnContext(..))

------------------------------------------------------------------------
-- Detect stack drift operation
------------------------------------------------------------------------

-- | Initiate drift detection for a CloudFormation stack.
--
-- Steps:
--   1. Build a DetectStackDrift request for the given stack name.
--   2. Send the request to CloudFormation.
--   3. Return the drift detection ID from the response.
--
-- Note: DetectStackDrift is asynchronous. The returned ID can be used
-- with DescribeStackDriftDetectionStatus to poll for completion, and
-- DescribeStackResourceDrifts to retrieve actual drift details.
detectStackDrift :: CfnContext -> Text -> IO (Either Text Text)
detectStackDrift ctx stackName = do
  -- Step 1: Build the DetectStackDrift request
  let req = DSD.newDetectStackDrift stackName

  -- Step 2: Send the request
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

  -- Step 3: Return the detection ID
  pure $ Right resp.stackDriftDetectionId
