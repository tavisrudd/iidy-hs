-- | Lint (validate) a CloudFormation template via the AWS API.
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Iidy.Cfn.Operations.LintTemplate
  ( lintTemplate
  ) where

import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as T

import Control.Monad.Trans.Resource (runResourceT)

import qualified Amazonka
import qualified Amazonka.CloudFormation.ValidateTemplate as VT

import Iidy.Cfn.Context (CfnContext(..))
import Iidy.Cfn.TemplateLoader (loadCfnTemplate, TemplateResult(..), templateMaxBytes)
import Iidy.Cfn.Types (StackArgs(..))

------------------------------------------------------------------------
-- Lint template operation
------------------------------------------------------------------------

-- | Validate a CloudFormation template against the AWS API.
--
-- Returns 0 if valid, 1 if validation errors were found.
lintTemplate
  :: CfnContext
  -> StackArgs
  -> Maybe FilePath  -- ^ argsfile path for template resolution
  -> Text            -- ^ environment name
  -> IO (Either Text Int)
lintTemplate ctx args argsfilePath env = do
  -- Load the template
  tmplResult <- loadCfnTemplate (saTemplate args) argsfilePath env

  case trTemplateBody tmplResult of
    Nothing -> pure (Left "Failed to load template body")
    Just body
      | T.length body > templateMaxBytes -> do
          -- Template too large for inline validation
          putStrLn "Warning: Template exceeds 51200 bytes; skipping API validation"
          pure (Right 0)
      | otherwise -> do
          let req = VT.newValidateTemplate
                      { VT.templateBody = Just body
                      }
          result <- try $ runResourceT $ Amazonka.send (cfnEnv ctx) req
          case result of
            Left (e :: SomeException) -> do
              putStrLn $ "Template validation failed: " <> show e
              pure (Right 1)
            Right _resp ->
              pure (Right 0)
