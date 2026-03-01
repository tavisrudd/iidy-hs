{-# LANGUAGE OverloadedRecordDot #-}
-- | SSM Parameter Store import loader.
module Iidy.Yaml.Imports.Loaders.Ssm
  ( loadSsmImport
  , parseSsmLocation
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Lens.Micro ((^.))

import qualified Amazonka
import qualified Amazonka.SSM.GetParameter as GP
import qualified Amazonka.SSM.Types.Parameter as SSMP

import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..), ImportType(..))
import Iidy.Yaml.Parser (parseYaml)
import Iidy.Yaml.Resolution.Resolver (astToValueRaw)

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

-- | Load a parameter from AWS SSM Parameter Store.
-- Accepts @ssm:/path/to/param@, @ssm:/path/to/param:json@, or @ssm:/path/to/param:yaml@.
-- Sets @withDecryption = True@ to support SecureString parameters.
loadSsmImport :: Amazonka.Env -> Text -> IO (Either ImportError ImportData)
loadSsmImport awsEnv location = do
  case parseSsmLocation location of
    Left err -> pure (Left err)
    Right (paramName, formatSuffix) -> do
      result <- try @SomeException (fetchSsmParam awsEnv paramName)
      case result of
        Left ex -> pure $ Left $ ImportError $
          "SSM fetch error for " <> paramName <> ": " <> T.pack (show ex)
        Right val ->
          case parseWithFormat formatSuffix val of
            Left err -> pure (Left err)
            Right doc -> pure $ Right $ ImportData
              { idType     = ImportSsm
              , idLocation = location
              , idRawData  = val
              , idDoc      = doc
              }

------------------------------------------------------------------------
-- SSM fetch
------------------------------------------------------------------------

-- | Fetch a parameter from SSM Parameter Store.
-- Uses @withDecryption = True@ to support SecureString parameters.
fetchSsmParam :: Amazonka.Env -> Text -> IO Text
fetchSsmParam awsEnv paramName = runResourceT $ do
  let req = (GP.newGetParameter paramName)
              { GP.withDecryption = Just True }
  resp <- Amazonka.send awsEnv req
  let param = resp.parameter
  pure (param ^. SSMP.parameter_value)

------------------------------------------------------------------------
-- Location parsing
------------------------------------------------------------------------

-- | Parse an SSM location into (parameterName, Maybe formatSuffix).
-- Format: @ssm:/path/to/param@ or @ssm:/path/to/param:json@ or @ssm:/path/to/param:yaml@.
-- The format suffix is the part after the second colon.
parseSsmLocation :: Text -> Either ImportError (Text, Maybe Text)
parseSsmLocation location =
  let stripped = maybe location id (T.stripPrefix "ssm:" location)
  in case T.breakOnEnd ":" stripped of
       -- breakOnEnd returns ("", rest) if no colon found
       ("", _) -> Right (stripped, Nothing)
       (prefix, suffix)
         | suffix == "json" || suffix == "yaml" ->
             let paramName = T.dropEnd 1 prefix  -- drop trailing ':'
             in if T.null paramName
                then Left $ ImportError $ "Invalid SSM parameter name in: " <> location
                else Right (paramName, Just suffix)
         | otherwise ->
             -- colon is part of the parameter path, not a format suffix
             Right (stripped, Nothing)

------------------------------------------------------------------------
-- Format-based parsing
------------------------------------------------------------------------

-- | Parse a value according to the specified format.
-- With no format, returns the raw string as a Value.
-- With :json or :yaml, parses and returns an error on failure (explicit user request).
parseWithFormat :: Maybe Text -> Text -> Either ImportError Value
parseWithFormat Nothing val = Right (String val)
parseWithFormat (Just "json") val =
  case Aeson.eitherDecodeStrict' (TE.encodeUtf8 val) of
    Right v -> Right v
    Left err -> Left $ ImportError $
      "Invalid JSON in SSM parameter: " <> T.pack err
parseWithFormat (Just "yaml") val =
  case parseYaml (BL.fromStrict (TE.encodeUtf8 val)) "<ssm-import>" of
    Right ast -> Right (astToValueRaw ast)
    Left err -> Left $ ImportError $
      "Invalid YAML in SSM parameter: " <> T.pack (show err)
parseWithFormat (Just _) val =
  -- Unknown format suffix, treat as no format
  Right (String val)
