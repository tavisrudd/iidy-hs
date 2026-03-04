{-# LANGUAGE OverloadedRecordDot #-}

{- | GetTemplate CloudFormation operation.

Retrieves the template body for a running or deleted stack.
-}
module Iidy.Cfn.Operations.GetStackTemplate (
    getStackTemplate,
) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Control.Monad.Trans.Resource (runResourceT)

import Amazonka qualified
import Amazonka.CloudFormation.GetTemplate qualified as GT

import Iidy.Cfn.Context (CfnContext (..))

------------------------------------------------------------------------
-- Get stack template operation
------------------------------------------------------------------------

{- | Retrieve the template body for a CloudFormation stack.

Steps:
  1. Build a GetTemplate request for the given stack name.
  2. Send the request to CloudFormation.
  3. Return the template body from the response.
-}
getStackTemplate :: CfnContext -> Text -> IO (Either Text Text)
getStackTemplate ctx stackName = do
    -- Step 1: Build the GetTemplate request
    let req =
            GT.newGetTemplate
                { GT.stackName = Just stackName
                }

    -- Step 2: Send the request
    resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

    -- Step 3: Return the template body
    pure $ Right (fromMaybe "" resp.templateBody)
