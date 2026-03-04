{-# LANGUAGE OverloadedRecordDot #-}

{- | EstimateTemplateCost CloudFormation operation.

Loads a template and calls the EstimateTemplateCost API,
returning the AWS Simple Monthly Calculator URL via OutputData.
-}
module Iidy.Cfn.Operations.EstimateCost (
    estimateCost,
) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Control.Monad.Trans.Resource (runResourceT)

import Amazonka qualified
import Amazonka.CloudFormation.EstimateTemplateCost qualified as ETC

import Iidy.Cfn.Context (CfnContext (..))
import Iidy.Cfn.TemplateLoader (TemplateResult (..), loadCfnTemplate)
import Iidy.Cfn.Types (StackArgs (..))
import Iidy.Output.Types
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig (..))

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
        env = cfnEnvironment ctx
    -- Step 1: Load the template
    tmplEither <- loadCfnTemplate (saTemplate args) argsfilePath env (ImportConfig (Just (cfnEnv ctx)) (cfnRemoteImports ctx))
    case tmplEither of
        Left err -> pure (Left err)
        Right tmplResult -> do
            -- Step 2: Build the EstimateTemplateCost request
            let req =
                    ETC.newEstimateTemplateCost
                        { ETC.templateBody = trTemplateBody tmplResult
                        , ETC.templateURL = trTemplateUrl tmplResult
                        }

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
