{-# LANGUAGE OverloadedRecordDot #-}
-- | SSM Parameter Store path import loader.
-- Fetches all parameters under a path recursively and returns them as a JSON object.
module Iidy.Yaml.Imports.Loaders.SsmPath
  ( loadSsmPathImport
  , parseSsmPathLocation
    -- * Pure helpers (exported for testing)
  , buildResultObject
  , stripPathPrefix
  ) where

import Control.Exception (try)
import Control.Monad.Trans.Resource (runResourceT)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Conduit (runConduit, (.|))
import qualified Data.Conduit.List as CL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Lens.Micro ((^.))

import qualified Amazonka
import qualified Amazonka.SSM.GetParametersByPath as GBP
import qualified Amazonka.SSM.Types.Parameter as SSMP

import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..), ImportType(..))
import Iidy.Yaml.Parser (parseYaml)
import Iidy.Yaml.Resolution.Resolver (astToValueRaw)

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

-- | Load all parameters under an SSM path recursively.
-- Accepts @ssm-path:/path/prefix@ or @ssm-path:/path/prefix:json@ or @ssm-path:/path/prefix:yaml@.
-- Returns a JSON object with relative parameter names as keys.
loadSsmPathImport :: Amazonka.Env -> Text -> IO (Either ImportError ImportData)
loadSsmPathImport awsEnv location = do
  case parseSsmPathLocation location of
    Left err -> pure (Left err)
    Right (paramPath, formatSuffix) -> do
      result <- try @Amazonka.Error (fetchParametersByPath awsEnv paramPath)
      case result of
        Left ex -> pure $ Left $ ImportError $
          "SSM path fetch error for " <> paramPath <> ": " <> T.pack (show ex)
        Right params ->
          let obj = buildResultObject paramPath formatSuffix params
              rawData = TE.decodeUtf8 (BL.toStrict (Aeson.encode obj))
          in pure $ Right $ ImportData
               { idType     = ImportSsmPath
               , idLocation = location
               , idRawData  = rawData
               , idDoc      = obj
               }

------------------------------------------------------------------------
-- SSM fetch
------------------------------------------------------------------------

-- | Fetch all parameters under a path recursively.
-- Uses withDecryption=True and recursive=True.
-- Paginates through all pages to avoid silent truncation at the
-- default SSM page size (max 10 results per page).
fetchParametersByPath :: Amazonka.Env -> Text -> IO [(Text, Text)]
fetchParametersByPath awsEnv paramPath = runResourceT $ do
  let req = (GBP.newGetParametersByPath paramPath)
              { GBP.recursive = Just True
              , GBP.withDecryption = Just True
              }
  pages <- runConduit $ Amazonka.paginate awsEnv req .| CL.consume
  let params = concatMap (fromMaybe [] . (.parameters)) pages
  pure [ (p ^. SSMP.parameter_name, p ^. SSMP.parameter_value)
       | p <- params
       ]

------------------------------------------------------------------------
-- Result building
------------------------------------------------------------------------

-- | Build a JSON object from parameters with relative keys.
-- Strips the base path prefix from each parameter name.
buildResultObject :: Text -> Maybe Text -> [(Text, Text)] -> Value
buildResultObject basePath formatSuffix params =
  let pairs = map (\(name, val) ->
        let relKey = stripPathPrefix basePath name
            parsedVal = parseParamValue formatSuffix val
        in (Key.fromText relKey, parsedVal)
        ) params
  in Object (KM.fromList pairs)

-- | Strip the base path prefix from a parameter name to get a relative key.
-- "/app/config/database/host" with base "/app/config" -> "database/host"
stripPathPrefix :: Text -> Text -> Text
stripPathPrefix basePath name =
  let stripped = fromMaybe name (T.stripPrefix basePath name)
      -- Strip leading slash after prefix removal
  in fromMaybe stripped (T.stripPrefix "/" stripped)

-- | Parse a parameter value according to the format suffix.
-- With :json or :yaml, attempts parse but falls back to string on failure.
-- Without format, treats as plain string.
parseParamValue :: Maybe Text -> Text -> Value
parseParamValue Nothing val = String val
parseParamValue (Just "json") val =
  case Aeson.eitherDecodeStrict' (TE.encodeUtf8 val) of
    Right v -> v
    Left _  -> String val  -- fallback on parse failure
parseParamValue (Just "yaml") val =
  case parseYaml (BL.fromStrict (TE.encodeUtf8 val)) "<ssm-path-import>" of
    Right ast -> astToValueRaw ast
    Left _    -> String val  -- fallback on parse failure
parseParamValue (Just _) val = String val  -- unknown format, treat as string

------------------------------------------------------------------------
-- Location parsing
------------------------------------------------------------------------

-- | Parse an SSM path location into (parameterPath, Maybe formatSuffix).
-- Format: @ssm-path:/path/prefix@ or @ssm-path:/path/prefix:json@ or @ssm-path:/path/prefix:yaml@.
parseSsmPathLocation :: Text -> Either ImportError (Text, Maybe Text)
parseSsmPathLocation location =
  let stripped = fromMaybe location (T.stripPrefix "ssm-path:" location)
  in if T.null stripped
     then Left $ ImportError $ "Invalid SSM parameter path in: " <> location
     else case T.breakOnEnd ":" stripped of
            -- breakOnEnd returns ("", rest) if no colon found
            ("", _) -> Right (stripped, Nothing)
            (prefix, suffix)
              | suffix == "json" || suffix == "yaml" ->
                  let paramPath = T.dropEnd 1 prefix  -- drop trailing ':'
                  in if T.null paramPath
                     then Left $ ImportError $ "Invalid SSM parameter path in: " <> location
                     else Right (paramPath, Just suffix)
              | otherwise ->
                  -- colon is part of the path, not a format suffix
                  Right (stripped, Nothing)
