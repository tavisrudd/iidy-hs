{-# LANGUAGE OverloadedRecordDot #-}
-- | SSM Parameter Store import loaders.
--
-- Handles both single-parameter (@ssm:@) and recursive-path (@ssm-path:@) imports.
module Iidy.Yaml.Imports.Loaders.Ssm
  ( loadSsmImport
  , loadSsmPathImport
  , parseSsmLocation
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
import qualified Amazonka.SSM.GetParameter as GP
import qualified Amazonka.SSM.GetParametersByPath as GBP
import qualified Amazonka.SSM.Types.Parameter as SSMP

import Iidy.Yaml.Imports.ContentParsing (parseByFormatSuffix, parseByFormatSuffixLenient)
import Iidy.Yaml.Imports.Types (ImportData(..), ImportError(..), ImportType(..))

------------------------------------------------------------------------
-- SSM single-parameter import
------------------------------------------------------------------------

-- | Load a parameter from AWS SSM Parameter Store.
-- Accepts @ssm:/path/to/param@, @ssm:/path/to/param:json@, or @ssm:/path/to/param:yaml@.
-- Sets @withDecryption = True@ to support SecureString parameters.
loadSsmImport :: Amazonka.Env -> Text -> IO (Either ImportError ImportData)
loadSsmImport awsEnv location = do
  case parseSsmLocation location of
    Left err -> pure (Left err)
    Right (paramName, formatSuffix) -> do
      result <- try @Amazonka.Error (fetchSsmParam awsEnv paramName)
      case result of
        Left ex -> pure $ Left $ ImportError $
          "SSM fetch error for " <> paramName <> ": " <> T.pack (show ex)
        Right val ->
          case parseByFormatSuffix formatSuffix val of
            Left err -> pure (Left err)
            Right doc -> pure $ Right $ ImportData
              { idType     = ImportSsm
              , idLocation = location
              , idRawData  = val
              , idDoc      = doc
              }

------------------------------------------------------------------------
-- SSM path (recursive) import
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
-- SSM fetch operations
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
-- Location parsing
------------------------------------------------------------------------

-- | Parse an SSM location into (parameterName, Maybe formatSuffix).
-- Format: @ssm:/path/to/param@ or @ssm:/path/to/param:json@ or @ssm:/path/to/param:yaml@.
-- The format suffix is the part after the last colon if it is @json@ or @yaml@.
parseSsmLocation :: Text -> Either ImportError (Text, Maybe Text)
parseSsmLocation location =
  let stripped = maybe location id (T.stripPrefix "ssm:" location)
  in parseFormatSuffix "SSM parameter name" location stripped

-- | Parse an SSM path location into (parameterPath, Maybe formatSuffix).
-- Format: @ssm-path:/path/prefix@ or @ssm-path:/path/prefix:json@ or @ssm-path:/path/prefix:yaml@.
parseSsmPathLocation :: Text -> Either ImportError (Text, Maybe Text)
parseSsmPathLocation location =
  let stripped = fromMaybe location (T.stripPrefix "ssm-path:" location)
  in if T.null stripped
     then Left $ ImportError $ "Invalid SSM parameter path in: " <> location
     else parseFormatSuffix "SSM parameter path" location stripped

-- | Shared format-suffix parsing for SSM location strings.
-- Recognises a trailing @:json@ or @:yaml@ as a format suffix;
-- any other colon-separated suffix is treated as part of the path.
parseFormatSuffix :: Text -> Text -> Text -> Either ImportError (Text, Maybe Text)
parseFormatSuffix entityLabel originalLocation stripped =
  case T.breakOnEnd ":" stripped of
    -- breakOnEnd returns ("", rest) if no colon found
    ("", _) -> Right (stripped, Nothing)
    (prefix, suffix)
      | suffix == "json" || suffix == "yaml" ->
          let name = T.dropEnd 1 prefix  -- drop trailing ':'
          in if T.null name
             then Left $ ImportError $ "Invalid " <> entityLabel <> " in: " <> originalLocation
             else Right (name, Just suffix)
      | otherwise ->
          -- colon is part of the path, not a format suffix
          Right (stripped, Nothing)

------------------------------------------------------------------------
-- Result building (SSM path)
------------------------------------------------------------------------

-- | Build a JSON object from parameters with relative keys.
-- Strips the base path prefix from each parameter name.
buildResultObject :: Text -> Maybe Text -> [(Text, Text)] -> Value
buildResultObject basePath formatSuffix params =
  let pairs = map (\(name, val) ->
        let relKey = stripPathPrefix basePath name
            parsedVal = parseByFormatSuffixLenient formatSuffix val
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
