-- | EstimateTemplateCost CloudFormation operation.
--
-- Loads a template and calls the EstimateTemplateCost API,
-- returning the AWS Simple Monthly Calculator URL via OutputData.
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
import Iidy.Output.Types

------------------------------------------------------------------------
-- Estimate cost operation
------------------------------------------------------------------------

-- | Estimate the monthly cost of a CloudFormation template.
--
-- Emits OdCostEstimate via the output pipeline.
estimateCost
  :: CfnContext
  -> StackArgs
  -> Maybe FilePath  -- ^ argsfile path for template resolution
  -> Text            -- ^ environment name
  -> (OutputData -> IO ())  -- ^ emit callback
  -> IO (Either Text Int)
estimateCost ctx args argsfilePath env emit = do
  -- Step 1: Load the template
  tmplResult <- loadCfnTemplate (saTemplate args) argsfilePath env (Just (cfnEnv ctx))

  -- Step 2: Build the EstimateTemplateCost request
  let req = ETC.newEstimateTemplateCost
              { ETC.templateBody = trTemplateBody tmplResult
              , ETC.templateURL  = trTemplateUrl tmplResult
              }

  -- Step 3: Send the request
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

  -- Step 4: Emit CostEstimate via output pipeline
  let url = fromMaybe "" resp.url
      costInfo = CostEstimateInfo
        { ceiUrl          = url
        , ceiStackName    = saStackName args
        , ceiTemplateFile = saTemplate args
        }
  emit (OdCostEstimate (CostEstimate { ceInfo = costInfo }))
  pure $ Right 0
