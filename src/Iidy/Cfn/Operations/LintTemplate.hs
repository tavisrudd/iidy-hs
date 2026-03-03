-- | Lint (validate) a CloudFormation template via the AWS API.
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Iidy.Cfn.Operations.LintTemplate
  ( lintTemplate
  ) where

import Control.Exception (try)
import Data.Text (Text)
import qualified Data.Text as T

import Control.Monad.Trans.Resource (runResourceT)

import qualified Amazonka
import qualified Amazonka.CloudFormation.ValidateTemplate as VT

import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.TemplateLoader (loadCfnTemplate, TemplateResult(..), templateMaxBytes)
import Iidy.Cfn.Types (StackArgs(..))
import Iidy.Output.Types
import Iidy.Yaml.Imports.Loaders.Dispatch (ImportConfig(..))
import Iidy.Yaml.Imports.Types (RemoteImports(..))

------------------------------------------------------------------------
-- Lint template operation
------------------------------------------------------------------------

-- | Validate a CloudFormation template against the AWS API.
--
-- Constructs a TemplateValidation and emits it via the output pipeline.
-- Returns 0 if valid, 1 if validation errors were found.
lintTemplate
  :: CfnContext
  -> StackArgs
  -> Maybe FilePath  -- ^ argsfile path for template resolution
  -> Text            -- ^ environment name
  -> (OutputData -> IO ())  -- ^ emit callback
  -> RemoteImports   -- ^ whether HTTP/S3 imports are allowed
  -> IO (Either Text Int)
lintTemplate ctx args argsfilePath env emit remoteImports = do
  -- Load the template
  tmplEither <- loadCfnTemplate (saTemplate args) argsfilePath env (ImportConfig (Just (cfnEnv ctx)) remoteImports)
  case tmplEither of
    Left err -> pure (Left err)
    Right tmplResult -> case trTemplateBody tmplResult of
      Nothing -> pure (Left "Failed to load template body")
      Just body -> do
        validation <- if T.length body > templateMaxBytes
          then
            -- Template too large for inline validation
            pure TemplateValidation
              { tvEnabled  = True
              , tvErrors   = []
              , tvWarnings = ["Template exceeds 51200 bytes; skipping CFN validation (will be validated on deploy)"]
              }
          else do
            let req = VT.newValidateTemplate
                        { VT.templateBody = Just body
                        }
            result <- try @Amazonka.Error $ runResourceT $ Amazonka.send (cfnEnv ctx) req
            case result of
              Left e ->
                pure TemplateValidation
                  { tvEnabled  = True
                  , tvErrors   = ["Template validation failed: " <> T.pack (show e)]
                  , tvWarnings = []
                  }
              Right _resp ->
                pure TemplateValidation
                  { tvEnabled  = True
                  , tvErrors   = []
                  , tvWarnings = []
                  }
        emit (OdTemplateValidation validation)
        pure $ Right $ if null (tvErrors validation) then 0 else 1
