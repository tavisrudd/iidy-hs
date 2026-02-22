{-# LANGUAGE OverloadedRecordDot #-}
-- | SSM Parameter Store import loader.
module Iidy.Yaml.Imports.Loaders.Ssm
  ( loadSsmImport
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Text (Text)
import qualified Data.Text as T
import Control.Lens ((^.))

import qualified Amazonka
import qualified Amazonka.SSM.GetParameter as GP
import qualified Amazonka.SSM.Types.Parameter as SSMP

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

-- | Load a parameter from AWS SSM Parameter Store.
-- Accepts @ssm:/path/to/param@ or a bare parameter name/path.
-- Sets @withDecryption = True@ to support SecureString parameters.
-- Returns the decrypted parameter value as text, or an error message.
loadSsmImport :: Amazonka.Env -> Text -> IO (Either Text Text)
loadSsmImport awsEnv location = do
  let paramName = stripSsmPrefix location
  result <- try @SomeException (fetchSsmParam awsEnv paramName)
  case result of
    Left ex  -> pure $ Left $ "SSM fetch error for " <> paramName <> ": " <> T.pack (show ex)
    Right val -> pure (Right val)

------------------------------------------------------------------------
-- SSM fetch
------------------------------------------------------------------------

-- | Fetch a parameter from SSM Parameter Store.
-- Uses @withDecryption = True@ to support SecureString parameters.
-- The @parameter_value@ lens unwraps the @Sensitive@ wrapper automatically.
fetchSsmParam :: Amazonka.Env -> Text -> IO Text
fetchSsmParam awsEnv paramName = runResourceT $ do
  let req = (GP.newGetParameter paramName)
              { GP.withDecryption = Just True }
  resp <- Amazonka.send awsEnv req
  let param = resp.parameter
  pure (param ^. SSMP.parameter_value)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- | Strip the @ssm:@ prefix from a location string.
stripSsmPrefix :: Text -> Text
stripSsmPrefix loc =
  maybe loc id (T.stripPrefix "ssm:" loc)
