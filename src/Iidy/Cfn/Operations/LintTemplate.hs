{-# LANGUAGE ScopedTypeVariables #-}

-- | Lint (validate) a CloudFormation template via the AWS API.
module Iidy.Cfn.Operations.LintTemplate (
    lintTemplate,
    validateTemplateBody,
) where

import Control.Exception (try)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Control.Monad.Trans.Resource (runResourceT)

import Amazonka qualified
import Amazonka.CloudFormation.ValidateTemplate qualified as VT

import Iidy.Cfn.Context (CfnContext (..), cfnImportConfig)
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
    CfnContext ->
    StackArgs ->
    -- | argsfile path for template resolution
    Maybe FilePath ->
    IO (Either Text Int)
lintTemplate ctx args argsfilePath = do
    let emit = cfnEmit ctx
        env = cfnEnvironment ctx
    -- Load the template
    tmplEither <- loadCfnTemplate (saTemplate args) argsfilePath env (cfnImportConfig ctx)
    case tmplEither of
        Left err -> pure (Left err)
        Right tmplResult -> case trTemplateBody tmplResult of
            Nothing -> pure (Left "Failed to load template body")
            Just body -> do
                validation <- validateTemplateBody ctx body
                emit (OdTemplateValidation validation)
                pure $ Right $ if null (tvErrors validation) then 0 else 1

{- | Validate a template body with CloudFormation @ValidateTemplate@. A body
over the inline limit (in UTF-8 bytes) is not sent: the result carries a
warning instead. Any AWS error, including access and network errors, is a
validation error.
-}
validateTemplateBody :: CfnContext -> Text -> IO TemplateValidation
validateTemplateBody ctx body
    | BS.length (TE.encodeUtf8 body) > templateMaxBytes =
        -- Template too large for inline validation
        pure
            TemplateValidation
                { tvEnabled = True
                , tvErrors = []
                , tvWarnings = ["Template exceeds 51200 bytes; skipping CFN validation (will be validated on deploy)"]
                }
    | otherwise = do
        let req =
                VT.newValidateTemplate
                    { VT.templateBody = Just body
                    }
        result <- try @Amazonka.Error $ runResourceT $ Amazonka.send (cfnEnv ctx) req
        pure $ case result of
            Left e ->
                TemplateValidation
                    { tvEnabled = True
                    , tvErrors = ["Template validation failed: " <> T.pack (show e)]
                    , tvWarnings = []
                    }
            Right _resp ->
                TemplateValidation
                    { tvEnabled = True
                    , tvErrors = []
                    , tvWarnings = []
                    }
