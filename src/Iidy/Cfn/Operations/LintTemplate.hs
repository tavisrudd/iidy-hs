{-# LANGUAGE ScopedTypeVariables #-}

-- | Lint (validate) a CloudFormation template via the AWS API.
module Iidy.Cfn.Operations.LintTemplate (
    lintTemplate,
) where

import Control.Exception (try)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Data.Text qualified as T

import Control.Monad.Trans.Resource (runResourceT)

import Amazonka qualified
import Amazonka.CloudFormation.ValidateTemplate qualified as VT

import Iidy.Cfn.Context (CfnContext (..))
import Iidy.Cfn.Env (CfnM, askContext, askEnvName, emitOutput, mkImportConfig)
import Iidy.Cfn.TemplateLoader (TemplateResult (..), loadCfnTemplate, templateMaxBytes)
import Iidy.Cfn.Types (StackArgs (..))
import Iidy.Output.Types

------------------------------------------------------------------------
-- Lint template operation
------------------------------------------------------------------------

{- | Validate a CloudFormation template against the AWS API.

Constructs a TemplateValidation and emits it via the output pipeline.
Returns 0 if valid, 1 if validation errors were found.
-}
lintTemplate ::
    StackArgs ->
    -- | argsfile path for template resolution
    Maybe FilePath ->
    CfnM (Either Text Int)
lintTemplate args argsfilePath = do
    ctx <- askContext
    env <- askEnvName
    importCfg <- mkImportConfig
    -- Load the template
    tmplEither <- liftIO $ loadCfnTemplate (saTemplate args) argsfilePath env importCfg
    case tmplEither of
        Left err -> pure (Left err)
        Right tmplResult -> case trTemplateBody tmplResult of
            Nothing -> pure (Left "Failed to load template body")
            Just body -> do
                validation <-
                    liftIO $
                        if T.length body > templateMaxBytes
                            then
                                -- Template too large for inline validation
                                pure
                                    TemplateValidation
                                        { tvEnabled = True
                                        , tvErrors = []
                                        , tvWarnings = ["Template exceeds 51200 bytes; skipping CFN validation (will be validated on deploy)"]
                                        }
                            else do
                                let req =
                                        VT.newValidateTemplate
                                            { VT.templateBody = Just body
                                            }
                                result <- try @Amazonka.Error $ runResourceT $ Amazonka.send (cfnEnv ctx) req
                                case result of
                                    Left e ->
                                        pure
                                            TemplateValidation
                                                { tvEnabled = True
                                                , tvErrors = ["Template validation failed: " <> T.pack (show e)]
                                                , tvWarnings = []
                                                }
                                    Right _resp ->
                                        pure
                                            TemplateValidation
                                                { tvEnabled = True
                                                , tvErrors = []
                                                , tvWarnings = []
                                                }
                emitOutput (OdTemplateValidation validation)
                pure $ Right $ if null (tvErrors validation) then 0 else 1
