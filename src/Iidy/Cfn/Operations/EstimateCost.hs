-- | EstimateTemplateCost CloudFormation operation.
--
-- Loads a template and calls the EstimateTemplateCost API,
-- returning the AWS Simple Monthly Calculator URL.
{-# LANGUAGE OverloadedRecordDot #-}
module Iidy.Cfn.Operations.EstimateCost
  ( estimateCost
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Control.Monad.Trans.Resource (runResourceT)

import qualified Amazonka
import qualified Amazonka.CloudFormation.EstimateTemplateCost as ETC

import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.TemplateLoader (loadCfnTemplate, TemplateResult(..))
import Iidy.Cfn.Types (StackArgs(..))

------------------------------------------------------------------------
-- Estimate cost operation
------------------------------------------------------------------------

-- | Estimate the monthly cost of a CloudFormation template.
--
-- Steps:
--   1. Load the template (body or URL) from StackArgs.
--   2. Build an EstimateTemplateCost request.
--   3. Send the request to CloudFormation.
--   4. Return the AWS Simple Monthly Calculator URL from the response.
estimateCost
  :: CfnContext
  -> StackArgs
  -> Maybe FilePath  -- ^ argsfile path for template resolution
  -> Text            -- ^ environment name
  -> IO (Either Text Text)
estimateCost ctx args argsfilePath env = do
  -- Step 1: Load the template
  tmplResult <- loadCfnTemplate (saTemplate args) argsfilePath env

  -- Step 2: Build the EstimateTemplateCost request
  let req = ETC.newEstimateTemplateCost
              { ETC.templateBody = trTemplateBody tmplResult
              , ETC.templateURL  = trTemplateUrl tmplResult
              }

  -- Step 3: Send the request
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

  -- Step 4: Extract the URL from the response
  pure $ Right (fromMaybe "" resp.url)
