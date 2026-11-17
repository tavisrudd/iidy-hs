{-# LANGUAGE OverloadedRecordDot #-}

{- | EstimateTemplateCost CloudFormation operation.

Loads a template and calls the EstimateTemplateCost API,
returning the AWS Simple Monthly Calculator URL via OutputData.
-}
module Iidy.Cfn.Operations.EstimateCost (
    estimateCost,
    buildEstimateCostRequest,
) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Control.Monad.Trans.Resource (runResourceT)

import Amazonka qualified
import Amazonka.CloudFormation.EstimateTemplateCost qualified as ETC

import Iidy.Cfn.ApprovedTemplate (resolveDeployTemplate)
import Iidy.Cfn.Context (CfnContext (..))
import Iidy.Cfn.TemplateLoader (TemplateResult (..))
import Iidy.Cfn.Types (StackArgs (..))
import Iidy.Output.Types

------------------------------------------------------------------------
-- Estimate cost operation
------------------------------------------------------------------------

{- | Estimate the monthly cost of a CloudFormation template.

Emits OdCostEstimate via the output pipeline.
-}
estimateCost ::
    CfnContext ->
    StackArgs ->
    -- | argsfile path for template resolution
    Maybe FilePath ->
    IO (Either Text Int)
estimateCost ctx args argsfilePath = do
    let emit = cfnEmit ctx
    -- Steps 1-2: Resolve the template and build the request
    reqEither <- buildEstimateCostRequest ctx args argsfilePath
    case reqEither of
        Left err -> pure (Left err)
        Right req -> do
            -- Step 3: Send the request
            resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req

            -- Step 4: Emit CostEstimate via output pipeline
            let url = fromMaybe "" resp.url
                costInfo =
                    CostEstimateInfo
                        { ceiUrl = url
                        , ceiStackName = Just (saStackName args)
                        , ceiTemplateFile = saTemplate args
                        }
            emit (OdCostEstimate (CostEstimate{ceInfo = costInfo}))
            pure $ Right 0

{- | Build the EstimateTemplateCost request. The template comes from
'resolveDeployTemplate', as for the deploy builders: with approval on, the
presigned URL of the approved object, or a refusal before any
CloudFormation call (iidy-js sends the approved URL here without its own
check, @estimateStackCost.ts:9-11@).
-}
buildEstimateCostRequest ::
    CfnContext ->
    StackArgs ->
    -- | argsfile path for template resolution
    Maybe FilePath ->
    IO (Either Text ETC.EstimateTemplateCost)
buildEstimateCostRequest ctx args argsfilePath = do
    tmplEither <- resolveDeployTemplate ctx args argsfilePath
    pure $ do
        tmplResult <- tmplEither
        Right
            ETC.newEstimateTemplateCost
                { ETC.templateBody = trTemplateBody tmplResult
                , ETC.templateURL = trTemplateUrl tmplResult
                }
